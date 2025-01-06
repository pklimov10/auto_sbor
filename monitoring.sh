#!/bin/bash

# Константы для цветового оформления
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color
# Константы для thread dump
readonly MAX_DUMPS=6                  # Максимальное количество дампов
readonly MAX_RETRIES=3               # Максимальное количество попыток
readonly TIMEOUT=30                  # Таймаут в секундах
readonly THREAD_DUMP_INTERVAL=60     # Интервал между дампами в секунда
# Переменные окружения
WFHOME=/u01/CM/wildfly
STANDALONEXML=$WFHOME/standalone/configuration/standalone.xml
ERRORHOME=/home/wildfly/
javahome=/u01/CM/java
javaclass=/u01/CM/cm-data/scripts/

# Функция для логирования с поддержкой уровней и цветов
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local color=""

    case $level in
        "ERROR") color=$RED ;;
        "WARNING") color=$YELLOW ;;
        "INFO") color=$GREEN ;;
        *) color=$NC ;;
    esac

    echo -e "${timestamp} [${color}${level}${NC}] ${message}"
}

# Функция проверки наличия необходимых директорий
check_directories() {
    local dirs=("$WFHOME" "$ERRORHOME" "$javahome" "$javaclass")
    local missing_dirs=()

    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            missing_dirs+=("$dir")
        fi
    done

    if [ ${#missing_dirs[@]} -ne 0 ]; then
        log "ERROR" "Following directories do not exist:"
        for dir in "${missing_dirs[@]}"; do
            log "ERROR" "  - $dir"
        done
        exit 1
    fi
}

# Функция для создания временной директории
create_temp_dir() {
    local temp_dir="$ERRORHOME/tmp"
    if [ ! -d "$temp_dir" ]; then
        if ! mkdir -p "$temp_dir" 2>/dev/null; then
            log "ERROR" "Failed to create temporary directory: $temp_dir"
            exit 1
        fi
        log "INFO" "Created temporary directory: $temp_dir"
    fi

    # Проверка прав на запись
    if [ ! -w "$temp_dir" ]; then
        log "ERROR" "No write permission for directory: $temp_dir"
        exit 1
    fi
}
get_jboss_pids() {
    local pids=()
    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        pids+=("$pid")
    done < <("$javahome/bin/jps" -v | grep jboss-modules)

    echo "${pids[@]}"
}

# Функция для извлечения данных из XML
extract_xml_value() {
    local pattern=$1
    local field=$2
    cat "$STANDALONEXML" | grep -A 30 "$pattern" | grep "$field" | sed 's/ //g' | sed 's/</ /g; s/>/ /g' | awk '{print $2}'
}

# Функция получения параметров подключения к базе данных
get_db_connection_params() {
    local pool_name=$1
    local params
    params=$(cat "$STANDALONEXML" | grep -A 30 "pool-name=\"$pool_name\"" | grep jdbc:postgresql |
             sed 's/ //g' | sed 's/\/\// /' | awk '{print $2}' |
             sed 's/:/ /;s/\// /g' | grep -v cm6 | grep -v cm5)

    echo "$params"
}

# Функция для получения системной информации
get_system_info() {
    log "INFO" "Collecting system information..."

    # Java Home
    my_java_home=$(systemctl status wildfly | grep Standalone | awk '{print $2}')

    # JDBC Driver
    JDBCDRIVERNAME=$(extract_xml_value 'pool-name="CM5"' 'driver')
    JDBCFILELOCATION="$WFHOME/standalone/deployments/$JDBCDRIVERNAME"

    # Database connection parameters
    local cm5_params=$(get_db_connection_params "CM5")
    local cmj_params=$(get_db_connection_params "CMJ")

    # CM5 parameters
    IP_CM5=$(echo "$cm5_params" | awk '{print $1}')
    PORT_CM5=$(echo "$cm5_params" | awk '{print $2}')
    DB_CN5_NAME=$(echo "$cm5_params" | awk '{print $3}' | sed 's/?.*$//')
    DB_CM5_USER=$(extract_xml_value 'pool-name="CM5"' 'user-name')
    DB_CM5_PASS=$(extract_xml_value 'pool-name="CM5"' 'password')

    # CMJ parameters
    IP_CMJ=$(echo "$cmj_params" | awk '{print $1}')
    PORT_CMJ=$(echo "$cmj_params" | awk '{print $2}')
    DB_CNJ_NAME=$(echo "$cmj_params" | awk '{print $3}' | sed 's/?.*$//')
    DB_CMJ_USER=$(extract_xml_value 'pool-name="CMJ"' 'user-name')
    DB_CMJ_PASS=$(extract_xml_value 'pool-name="CMJ"' 'password')

    display_system_info
}

# Функция отображения системной информации
display_system_info() {
    log "INFO" "=== System Information ==="
    echo "JDBC Driver: $JDBCFILELOCATION"
    echo "CM5 Database: $IP_CM5:$PORT_CM5/$DB_CN5_NAME"
    echo "CMJ Database: $IP_CMJ:$PORT_CMJ/$DB_CNJ_NAME"
    echo "Java Home: $my_java_home"
    echo "Available Memory: $(free -m | grep Mem | awk '{print $4}') MB"
}

# Функция сбора логов
collect_logs() {
    log "INFO" "Collecting logs..."
    local archive_name="$(hostname)_$(date +'log_%Y.%m.%d_%H-%M-%S').tar.gz"
    tar -czf "$ERRORHOME/$archive_name" "$WFHOME/standalone/log/"*.log
    log "INFO" "Logs archived: $ERRORHOME/$archive_name"
}

# Функция выполнения SQL-запроса
execute_sql_query() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    local db=$5
    local query=$6
    local output=$7

    "$my_java_home" -cp "$JDBCFILELOCATION:$javaclass" PostgresqlQueryExecuteJDBC -h "$host" -p "$port" -U "$user" -W "$pass" -d "$db" -c "$query" > "$output"
}

# Функция сбора информации о SQL
collect_sql_info() {
    local timestamp=$(date +"%Y-%m-%d-%H-%M")
    local output_dir="$ERRORHOME/$timestamp"
    mkdir -p "$output_dir"

    log "INFO" "Collecting SQL information..."

    # Collect pool information
    collect_pool_info "$output_dir" "CM5" "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME"
    collect_pool_info "$output_dir" "CMJ" "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME"

    # Collect query information for CM5
    # All queries
    execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
        "select (now() - query_start) as time_in_progress, datname, pid, state, client_addr, client_hostname, client_port, query
         from pg_stat_activity ORDER BY time_in_progress desc" \
        "$output_dir/$(date +'zapros-CM5-%Y-%m-%d-%H-%M').csv"

    # Active queries
    execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
        "select (now() - query_start) as time_in_progress, datname, pid, state, client_addr, client_hostname, client_port, query
         from pg_stat_activity where state = 'active' ORDER BY time_in_progress desc" \
        "$output_dir/$(date +'zapros-active-CM5-%Y-%m-%d-%H-%M').csv"

    # Blocked queries and locks for CM5
    execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
        "select bda.pid as blocked_pid,
                bda.query as blocked_query,
                bga.pid as blocking_pid,
                bga.query as blocking_query
         from pg_catalog.pg_locks bdl
         join pg_stat_activity bda on bda.pid = bdl.pid
         join pg_catalog.pg_locks bgl on bgl.pid != bdl.pid and bgl.transactionid = bdl.transactionid
         join pg_stat_activity bga on bga.pid = bgl.pid
         where not bdl.granted and bga.datname = 'cm5';" \
        "$output_dir/$(date +'block-active-CM5-%Y-%m-%d-%H-%M').csv"

    # Collect query information for CMJ
    # All queries
    execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
        "select (now() - query_start) as time_in_progress, datname, pid, state, client_addr, client_hostname, client_port, query
         from pg_stat_activity ORDER BY time_in_progress desc" \
        "$output_dir/$(date +'zapros-CMJ-%Y-%m-%d-%H-%M').csv"

    # Active queries
    execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
        "select (now() - query_start) as time_in_progress, datname, pid, state, client_addr, client_hostname, client_port, query
         from pg_stat_activity where state = 'active' ORDER BY time_in_progress desc" \
        "$output_dir/$(date +'zapros-active-CMJ-%Y-%m-%d-%H-%M').csv"

    # Blocked queries and locks for CMJ
    execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
        "select bda.pid as blocked_pid,
                bda.query as blocked_query,
                bga.pid as blocking_pid,
                bga.query as blocking_query
         from pg_catalog.pg_locks bdl
         join pg_stat_activity bda on bda.pid = bdl.pid
         join pg_catalog.pg_locks bgl on bgl.pid != bdl.pid and bgl.transactionid = bdl.transactionid
         join pg_stat_activity bga on bga.pid = bgl.pid
         where not bdl.granted and bga.datname = 'cmj';" \
        "$output_dir/$(date +'block-active-CMJ-%Y-%m-%d-%H-%M').csv"

    # Collect additional pool statistics
    collect_extended_pool_stats "$output_dir"

    log "INFO" "SQL information collected in: $output_dir"
}

# Функция сбора расширенной статистики пулов
collect_extended_pool_stats() {
    local output_dir=$1
    local cm5_pool_file="$output_dir/$(date +'pool_cm5_%Y.%m.%d_%H-%M-%S').txt"
    local cmj_pool_file="$output_dir/$(date +'pool_cmj_%Y.%m.%d_%H-%M-%S').txt"

    # CM5 Pool Statistics
    {
        echo "=== CM5 Pool Statistics ==="
        # Max connections
        echo -n "Total available pools: "
        execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
            "show max_connections" | grep -v max_connections

        # Used connections
        echo -n "Total used pools: "
        execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
            "SELECT COUNT(*) FROM pg_stat_activity" | grep -v count

        # Active connections
        echo -n "Active pools: "
        execute_sql_query "$IP_CM5" "$PORT_CM5" "$DB_CM5_USER" "$DB_CM5_PASS" "$DB_CN5_NAME" \
            "SELECT COUNT(*) FROM pg_stat_activity where state = 'active'" | grep -v count
    } > "$cm5_pool_file"

    # CMJ Pool Statistics
    {
        echo "=== CMJ Pool Statistics ==="
        # Max connections
        echo -n "Total available pools: "
        execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
            "show max_connections" | grep -v max_connections

        # Used connections
        echo -n "Total used pools: "
        execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
            "SELECT COUNT(*) FROM pg_stat_activity" | grep -v count

        # Active connections
        echo -n "Active pools: "
        execute_sql_query "$IP_CMJ" "$PORT_CMJ" "$DB_CMJ_USER" "$DB_CMJ_PASS" "$DB_CNJ_NAME" \
            "SELECT COUNT(*) FROM pg_stat_activity where state = 'active'" | grep -v count
    } > "$cmj_pool_file"
}
# Функция сбора информации о пулах
collect_pool_info() {
    local output_dir=$1
    local db_name=$2
    local host=$3
    local port=$4
    local user=$5
    local pass=$6
    local db=$7

    local pool_file="$output_dir/$(hostname)_pool_${db_name}_$(date +'%Y.%m.%d_%H-%M-%S').txt"

    # Get max connections
    local max_conn=$(execute_sql_query "$host" "$port" "$user" "$pass" "$db" \
        "show max_connections" | grep -v max_connections)

    # Get active connections
    local active_conn=$(execute_sql_query "$host" "$port" "$user" "$pass" "$db" \
        "SELECT COUNT(*) FROM pg_stat_activity" | grep -v count)

    # Get active state connections
    local active_state=$(execute_sql_query "$host" "$port" "$user" "$pass" "$db" \
        "SELECT COUNT(*) FROM pg_stat_activity where state = 'active'" | grep -v count)

    echo "Max connections: $max_conn" > "$pool_file"
    echo "Active connections: $active_conn" >> "$pool_file"
    echo "Active state connections: $active_state" >> "$pool_file"
}

# Функция сбора thread dumps
# Функция сбора thread dumps
collect_thread_dumps() {
    log "INFO" "Starting thread dump collection..."
    local pids=($(get_jboss_pids))

    # Проверяем, что массив pids не пустой
    if [ ${#pids[@]} -eq 0 ]; then
        log "ERROR" "No JBoss processes found"
        return 1
    fi

    log "INFO" "Found ${#pids[@]} JBoss process(es)"

    # Создаем временную директорию, если её нет
    mkdir -p "$ERRORHOME/tmp"

    local count=0
    while [ "$count" -lt "$MAX_DUMPS" ]; do
        log "INFO" "Collecting thread dump set $((count + 1)) of $MAX_DUMPS"

        local dumps_collected=0
        for pid in "${pids[@]}"; do
            local dump_file="$ERRORHOME/tmp/$(hostname)_pid${pid}_$(date +'ThreadDump_%Y.%m.%d_%H-%M-%S').csv"

            # Проверяем существование процесса перед сбором dump
            if ! kill -0 "$pid" 2>/dev/null; then
                log "WARNING" "Process $pid no longer exists"
                continue
            fi

            # Попытка получить thread dump с повторами при неудаче
            local retry=0
            while [ "$retry" -lt "$MAX_RETRIES" ]; do
                if [ -x "$javahome/bin/jcmd" ] && timeout "$TIMEOUT" "$javahome/bin/jcmd" "$pid" Thread.print > "$dump_file" 2>/dev/null; then
                    log "INFO" "Successfully collected thread dump for PID $pid"
                    ((dumps_collected++))
                    break
                else
                    ((retry++))
                    if [ "$retry" -eq "$MAX_RETRIES" ]; then
                        log "ERROR" "Failed to collect thread dump for PID $pid after $MAX_RETRIES attempts"
                    else
                        log "WARNING" "Retry $retry/$MAX_RETRIES for PID $pid"
                        sleep 2
                    fi
                fi
            done
        done

        # Проверяем, были ли собраны dumps в этой итерации
        if [ "$dumps_collected" -eq 0 ]; then
            log "ERROR" "No thread dumps collected in this iteration"
            break
        fi

        ((count++))
        [ "$count" -lt "$MAX_DUMPS" ] && sleep "$THREAD_DUMP_INTERVAL"
    done

    # Проверяем наличие файлов перед архивацией
    if [ -n "$(ls -A "$ERRORHOME/tmp/" 2>/dev/null)" ]; then
        archive_thread_dumps
    else
        log "ERROR" "No thread dumps found to archive"
        return 1
    fi
}



# Функция архивации thread dumps
archive_thread_dumps() {
    local archive_name="$(hostname)_$(date +'ThreadDump_%Y.%m.%d_%H-%M-%S').tar.gz"
    local archive_path="$ERRORHOME/$archive_name"

    if [ ! -d "$ERRORHOME/tmp" ] || [ -z "$(ls -A "$ERRORHOME/tmp")" ]; then
        log "ERROR" "No thread dumps found to archive"
        return 1
    fi

    if tar -czf "$archive_path" -C "$ERRORHOME/tmp" . ; then
        log "INFO" "Thread dumps archived successfully: $archive_path"
        # Подсчет количества файлов в архиве
        local file_count=$(tar -tf "$archive_path" | wc -l)
        log "INFO" "Archive contains $file_count files"

        # Очистка временных файлов
        rm -f "$ERRORHOME/tmp"/*.csv
        return 0
    else
        log "ERROR" "Failed to create thread dump archive"
        return 1
    fi
}

# Функция сбора всей информации
collect_all() {
    log "INFO" "Starting collection of all diagnostic information..."
    local timestamp=$(date +"%Y-%m-%d-%H-%M")
    local output_dir="$ERRORHOME/$timestamp"

    if ! mkdir -p "$output_dir"; then
        log "ERROR" "Failed to create output directory: $output_dir"
        return 1
    fi

    local success=true

    collect_logs || success=false
    collect_thread_dumps || success=false
    collect_sql_info || success=false

    if $success; then
        log "INFO" "All diagnostic information collected successfully in: $output_dir"
        return 0
    else
        log "WARNING" "Some collections failed, check logs for details"
        return 1
    fi
}
# Функция отображения помощи
show_usage() {
    echo "Usage: $0 <option>"
    echo "Options:"
    echo "  1 or log    - Collect logs"
    echo "  2 or thread - Collect thread dumps"
    echo "  3 or sql    - Collect SQL information"
    echo "  4 or all    - Collect all diagnostic information"
}

# Основная функция
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
            *) log "ERROR" "Invalid option: $1"
               show_usage ;;
        esac
    else
        show_usage
    fi
}

# Запуск скрипта
main "$@"