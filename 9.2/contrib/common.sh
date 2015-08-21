# Configuration settings.
export POSTGRESQL_MAX_CONNECTIONS=${POSTGRESQL_MAX_CONNECTIONS:-100}
export POSTGRESQL_SHARED_BUFFERS=${POSTGRESQL_SHARED_BUFFERS:-32MB}

export POSTGRESQL_RECOVERY_FILE=$HOME/openshift-custom-recovery.conf
export POSTGRESQL_CONFIG_FILE=$HOME/openshift-custom-postgresql.conf

psql_identifier_regex='^[a-zA-Z_][a-zA-Z0-9_]*$'
psql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

function usage() {
  if [ $# == 2 ]; then
    echo "error: $1"
  fi
  echo "You must specify the following environment variables:"
  echo "  POSTGRESQL_USER (regex: '$psql_identifier_regex')"
  echo "  POSTGRESQL_PASSWORD (regex: '$psql_password_regex')"
  echo "  POSTGRESQL_DATABASE (regex: '$psql_identifier_regex')"
  echo "Optional:"
  echo "  POSTGRESQL_ADMIN_PASSWORD (regex: '$psql_password_regex')"
  echo "Settings:"
  echo "  POSTGRESQL_MAX_CONNECTIONS (default: 100)"
  echo "  POSTGRESQL_SHARED_BUFFERS (default: 32MB)"
  exit 1
}

function check_env_vars() {
  if ! [[ -v POSTGRESQL_USER && -v POSTGRESQL_PASSWORD && -v POSTGRESQL_DATABASE ]]; then
    usage
  fi

  [[ "$POSTGRESQL_USER"     =~ $psql_identifier_regex ]] || usage
  [[ "$POSTGRESQL_PASSWORD" =~ $psql_password_regex   ]] || usage
  [[ "$POSTGRESQL_DATABASE" =~ $psql_identifier_regex ]] || usage
  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    [[ "$POSTGRESQL_ADMIN_PASSWORD" =~ $psql_password_regex ]] || usage
  fi
  [ ${#POSTGRESQL_USER}     -le 63 ] || usage "PostgreSQL username too long (maximum 63 characters)"
  [ ${#POSTGRESQL_DATABASE} -le 63 ] || usage "Database name too long (maximum 63 characters)"
}

# Make sure env variables don't propagate to PostgreSQL process.
function unset_env_vars() {
  unset POSTGRESQL_USER
  unset POSTGRESQL_PASSWORD
  unset POSTGRESQL_DATABASE
  unset POSTGRESQL_ADMIN_PASSWORD
}

# postgresql_master_addr lookups the 'postgresql-master' DNS and get list of the available
# endpoints. Each endpoint is a PostgreSQL container with the 'master' PostgreSQL running.
function postgresql_master_addr() {
  local service_name=${POSTGRESQL_MASTER_SERVICE_NAME:-postgresql-master}
  local endpoints=$(dig ${service_name} A +search | grep ";${service_name}" | cut -d ';' -f 2 2>/dev/null)
  # FIXME: This is for debugging (docker run)
  if [ -v POSTGRESQL_MASTER_IP ]; then
    endpoints=${POSTGRESQL_MASTER_IP:-}
  fi
  if [ -z "$endpoints" ]; then
    >&2 echo "Failed to resolve PostgreSQL master IP address"
    exit 3
  fi
  echo -n "$(echo $endpoints | cut -d ' ' -f 1)"
}

# New config is generated every time a container is created. It only contains
# additional custom settings and is included from $PGDATA/postgresql.conf.
function generate_postgresql_config() {
  envsubst < ${POSTGRESQL_CONFIG_FILE}.template > ${POSTGRESQL_CONFIG_FILE}
}

# Generate passwd file based on current uid
function generate_passwd_file() {
  export USER_ID=$(id -u)
  envsubst < ${HOME}/passwd.template > ${HOME}/passwd
  export LD_PRELOAD=libnss_wrapper.so
  export NSS_WRAPPER_PASSWD=/var/lib/pgsql/passwd
  export NSS_WRAPPER_GROUP=/etc/group
}

function initialize_database() {
  check_env_vars

  # Initialize the database cluster with utf8 support enabled by default.
  # This might affect performance, see:
  # http://www.postgresql.org/docs/9.2/static/locale.html
  LANG=${LANG:-en_US.utf8} initdb

  # PostgreSQL configuration.
  cat >> "$PGDATA/postgresql.conf" <<EOF

# Custom OpenShift configuration:
include '${POSTGRESQL_CONFIG_FILE}'
EOF

  # Access control configuration.
  cat >> "$PGDATA/pg_hba.conf" <<EOF

#
# Custom OpenShift configuration starting at this point.
#

# Allow connections from all hosts.
host all all all md5
EOF

  pg_ctl -w start
  createuser "$POSTGRESQL_USER"
  createdb --owner="$POSTGRESQL_USER" "$POSTGRESQL_DATABASE"

  if [ -v POSTGRESQL_MASTER_USER ]; then
    createuser "$POSTGRESQL_MASTER_USER"
  fi

  set_passwords

  pg_ctl stop
}

function set_passwords() {
  psql --command "ALTER USER \"${POSTGRESQL_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_PASSWORD}';"

  if [ -v POSTGRESQL_MASTER_USER ]; then
    psql --command "ALTER USER \"${POSTGRESQL_MASTER_USER}\" WITH REPLICATION;"
    psql --command "ALTER USER \"${POSTGRESQL_MASTER_USER}\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_MASTER_PASSWORD}';"
  fi

  if [ -v POSTGRESQL_ADMIN_PASSWORD ]; then
    psql --command "ALTER USER \"postgres\" WITH ENCRYPTED PASSWORD '${POSTGRESQL_ADMIN_PASSWORD}';"
  fi
}