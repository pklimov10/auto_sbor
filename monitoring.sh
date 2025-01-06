#!/bin/bash

# Константы для цветового оформления
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Функция для логирования
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}"
}

# Функция проверки наличия необходимых директорий
check_directories() {
    local dirs=("$WFHOME" "$ERRORHOME" "$javahome" "$javaclass")
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log "ERROR" "Directory ${dir} does not exist"
            exit 1
        fi
    done
}

# Функция для создания временной директории
create_temp_dir() {
    if [ ! -d "$ERRORHOME/tmp" ]; then
        mkdir -p "$ERRORHOME/tmp"
        log "INFO" "Created temporary directory: $ERRORHOME/tmp"
    fi
}

# Функция получения информации о системе
get_system_info() {
    log "INFO" "=== Collecting System Information ==="

    # Java Home path
    my_java_home=$(systemctl status wildfly | grep Standalone | awk '{print $2}')

    # Database driver information
    JDBCDRIVERNAME=$(cat $STANDALONEXML | grep -A 30 'pool-name="CM5"' | grep driver |
                     sed 's/</ /g; s/>/ /g' | grep -v 'name="h2"' | awk '{print $2}')
    JDBCFILELOCATION="$WFHOME/standalone/deployments/$JDBCDRIVERNAME"

    # Get database connection details
    parse_database_info

    # Display collected information
    display_system_info
}

# Функция для парсинга информации о базах данных
parse_database_info() {
    # CM5 database info
    IP_CM5=$(cat $STANDALONEXML | grep -A 30 'pool-name="CM5"' | grep jdbc:postgresql |
             sed 's/ //g' | sed 's/\/\// /' | awk '{print $2}' |
             sed 's/:/ /;s/\// /g' | awk '{print $1}')

    PORT_CM5=$(cat $STANDALONEXML | grep -A 30 'pool-name="CM5"' | grep jdbc:postgresql |
               sed 's/ //g' | sed 's/\/\// /' | awk '{print $2}' |
               sed 's/:/ /;s/\// /g' | awk '{print $2}')

    # CMJ database info
    IP_CMJ=$(cat $STANDALONEXML | grep -A 30 'pool-name="CMJ"' | grep jdbc:postgresql |
             sed 's/ //g' | sed 's/\/\// /' | awk '{print $2}' |
             sed 's/:/ /;s/\// /g' | grep -v cm6 | grep -v cm5 | awk '{print $1}')

    PORT_CMJ=$(cat $STANDALONEXML | grep -A 30 'pool-name="CMJ"' | grep jdbc:postgresql |
               sed 's/ //g' | sed 's/\/\// /' | awk '{print $2}' |
               sed 's/:/ /;s/\// /g' | grep -v cm6 | grep -v cm5 | awk '{print $2}')

    # Database names and credentials
    parse_database_credentials
}

# Функция для сбора логов
collect_logs() {
    log "INFO" "Collecting logs..."
    local archive_name="$(hostname)_$(date +'log_%Y.%m.%d_%H-%M-%S').tar.gz"
    tar -czf "$ERRORHOME/$archive_name" "$WFHOME/standalone/log/"*.log
    log "INFO" "Logs collected: $ERRORHOME/$archive_name"
}

# Функция для сбора heap dump
collect_heap_dump() {
    local pid=$1
    local dump_file="$ERRORHOME/tmp/$(hostname)_$(date +'HeapDump_%Y.%m.%d_%H-%M-%S').hprof"

    log "INFO" "Collecting heap dump for PID: $pid"
    "$javahome/bin/jmap" -dump:format=b,file="$dump_file" "$pid"

    if [ $? -eq 0 ]; then
        log "INFO" "Heap dump collected successfully: $dump_file"
        return 0
    else
        log "ERROR" "Failed to collect heap dump"
        return 1
    fi
}

# Функция для сбора GC статистики
collect_gc_stats() {
    local pid=$1
    local gc_file="$ERRORHOME/tmp/$(hostname)_$(date +'GC_%Y.%m.%d_%H-%M-%S').log"

    log "INFO" "Collecting GC statistics for PID: $pid"
    "$javahome/bin/jstat" -gcutil "$pid" 1000 10 > "$gc_file"

    if [ $? -eq 0 ]; then
        log "INFO" "GC statistics collected successfully: $gc_file"
        return 0
    else
        log "ERROR" "Failed to collect GC statistics"
        return 1
    fi
}

# Функция для получения информации о deadlocks
collect_deadlocks() {
    local pid=$1
    local deadlock_file="$ERRORHOME/tmp/$(hostname)_$(date +'Deadlock_%Y.%m.%d_%H-%M-%S').log"

    log "INFO" "Checking for deadlocks for PID: $pid"
    "$javahome/bin/jcmd" "$pid" Thread.print_deadlocks > "$deadlock_file"

    if [ -s "$deadlock_file" ]; then
        log "WARNING" "Deadlocks detected! Check $deadlock_file for details"
    else
        log "INFO" "No deadlocks detected"
        rm "$deadlock_file"
    fi
}

# Функция для сбора информации о memory pools
collect_memory_info() {
    local pid=$1
    local memory_file="$ERRORHOME/tmp/$(hostname)_$(date +'Memory_%Y.%m.%d_%H-%M-%S').log"

    log "INFO" "Collecting memory information for PID: $pid"
    {
        echo "=== Memory Pools Information ==="
        "$javahome/bin/jcmd" "$pid" VM.info
        echo -e "\n=== Memory Map ==="
        "$javahome/bin/jcmd" "$pid" VM.native_memory
        echo -e "\n=== Heap Info ==="
        "$javahome/bin/jmap" -heap "$pid"
    } > "$memory_file"

    if [ $? -eq 0 ]; then
        log "INFO" "Memory information collected successfully: $memory_file"
        return 0
    else
        log "ERROR" "Failed to collect memory information"
        return 1
    fi
}

# Улучшенная функция сбора thread dumps
collect_thread_dumps() {
    log "INFO" "Starting enhanced thread dump collection..."

    # Создаем директорию для текущей сессии
    local session_dir="$ERRORHOME/$(date +'%Y-%m-%d-%H-%M')"
    mkdir -p "$session_dir"

    # Получаем PID процесса
    local pid=$("$javahome/bin/jps" -v | grep jboss-modules | awk '{print $1}')
    if [ -z "$pid" ]; then
        log "ERROR" "JBoss process not found"
        return 1
    fi

    log "INFO" "Found JBoss process with PID: $pid"

    # Собираем базовую информацию о процессе
    local info_file="$session_dir/process_info.log"
    {
        echo "=== Process Information ==="
        echo "Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo "PID: $pid"
        echo -e "\n=== Java Version ==="
        "$javahome/bin/java" -version 2>&1
        echo -e "\n=== System Resources ==="
        free -h
        df -h
        echo -e "\n=== Process Resources ==="
        ps -o pid,ppid,user,%cpu,%mem,vsz,rss,comm -p "$pid"
    } > "$info_file"

    # Собираем thread dumps с интервалом
    local count=0
    local max_dumps=5
    local interval=10 # секунд между дампами

    while [ $count -lt $max_dumps ]; do
        local dump_file="$session_dir/ThreadDump_$(date +'%H-%M-%S').txt"

        log "INFO" "Collecting thread dump $((count + 1)) of $max_dumps"

        {
            echo "=== Thread Dump $((count + 1)) ==="
            echo "Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
            echo -e "\n=== Thread Stack Traces ==="
            "$javahome/bin/jstack" -l "$pid"
            echo -e "\n=== Locked Synchronizers ==="
            "$javahome/bin/jcmd" "$pid" Thread.print -l
            echo -e "\n=== Thread Contention Statistics ==="
            "$javahome/bin/jcmd" "$pid" Thread.print_stream_statistics
        } > "$dump_file"

        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to collect thread dump $((count + 1))"
            continue
        fi

        ((count++))

        # Собираем дополнительную информацию при первом проходе
        if [ $count -eq 1 ]; then
            collect_memory_info "$pid"
            collect_gc_stats "$pid"
            collect_deadlocks "$pid"

            # Собираем heap dump только если используется больше 80% heap
            local heap_usage=$(jstat -gcutil "$pid" | tail -n 1 | awk '{print $3+$4}')
            if (( $(echo "$heap_usage > 80" | bc -l) )); then
                log "WARNING" "High heap usage detected ($heap_usage%), collecting heap dump"
                collect_heap_dump "$pid"
            fi
        fi

        if [ $count -lt $max_dumps ]; then
            log "INFO" "Waiting $interval seconds before next dump..."
            sleep "$interval"
        fi
    done

    # Архивируем все собранные данные
    local archive_name="$(hostname)_$(date +'ThreadDumps_%Y.%m.%d_%H-%M-%S').tar.gz"
    log "INFO" "Archiving collected data..."

    tar -czf "$ERRORHOME/$archive_name" -C "$session_dir" .
    if [ $? -eq 0 ]; then
        log "INFO" "Thread dumps and additional data archived successfully: $ERRORHOME/$archive_name"
        rm -rf "$session_dir"
    else
        log "ERROR" "Failed to archive thread dumps"
        log "INFO" "Data remains in: $session_dir"
    fi
}

# Main execution starts here
main() {
    check_directories
    create_temp_dir
    get_system_info

    if [ -n "$1" ]; then
        case "$1" in
            log|1) collect_logs ;;
            thread|2) collect_thread_dumps ;;
            sql|3) collect_sql_info ;;
            all|4) collect_all ;;
            *) log "ERROR" "Invalid option: $1" ;;
        esac
    else
        show_usage
    fi
}

# Запуск основной функции
main "$@"