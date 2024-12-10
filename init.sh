#!/bin/bash
#/*
# * Copyright (c) 2012 Adobe Systems Incorporated. All rights reserved.
# *
# * Permission is hereby granted, free of charge, to any person obtaining a
# * copy of this software and associated documentation files (the "Software"),
# * to deal in the Software without restriction, including without limitation
# * the rights to use, copy, modify, merge, publish, distribute, sublicense,
# * and/or sell copies of the Software, and to permit persons to whom the
# * Software is furnished to do so, subject to the following conditions:
# *
# * The above copyright notice and this permission notice shall be included in
# * all copies or substantial portions of the Software.
# *
# * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# * DEALINGS IN THE SOFTWARE.
# *
# */
debug_mode=${DEBUG}
log_level=${LOG_LEVEL:-warn}
marathon_host=${MARATHON_HOST}
sleep_duration=${MARATHON_POLL_INTERVAL:-5}
active_active=${ACTIVE_ACTIVE:-false}
active_active_api_gateway_token=${ACTIVE_ACTIVE_API_GATEWAY_TOKEN}
active_active_set_upstream_interval=${ACTIVE_ACTIVE_SET_UPSTREAM_INTERVAL}
active_active_status_check_interval=${ACTIVE_ACTIVE_STATUS_CHECK_INTERVAL}
active_active_upstreams_csv_path=${ACTIVE_ACTIVE_UPSTREAMS_CSV_PATH}
#
# location for a remote /etc/api-gateway folder.
# i.e s3://api-gateway-config
#
remote_config=${REMOTE_CONFIG}
#
# How often to check for changes in configuration. Default: 10s
#
remote_config_sync_interval=${REMOTE_CONFIG_SYNC_INTERVAL:-10s}
#
# A custom sync command that overrides REMOTE_CONFIG var.
# This allows full control over what the sync command does.
#
remote_config_sync_cmd=${REMOTE_CONFIG_SYNC_CMD}

echo "Starting api-gateway ..."
if [ "${debug_mode}" == "true" ]; then
    echo "   ...  in DEBUG mode "
    mv /usr/local/sbin/api-gateway /usr/local/sbin/api-gateway-no-debug
    ln -sf /usr/local/sbin/api-gateway-debug /usr/local/sbin/api-gateway
fi

sudo /usr/local/sbin/api-gateway -V
echo "------"

echo resolver $(awk 'BEGIN{ORS=" "} /nameserver/{print $2}' /etc/resolv.conf | sed "s/ $/;/g") > /etc/api-gateway/conf.d/includes/resolvers.conf
echo "   ...  with dns $(cat /etc/api-gateway/conf.d/includes/resolvers.conf)"

sync_cmd="echo checking for changes ..."
if [[ -n "${remote_config}" ]]; then
    echo "   ... using a remote config from: ${remote_config}"
    if [[ "${remote_config}" =~ ^s3://.+ ]]; then
      sync_cmd="aws s3 sync --exclude *resolvers.conf --exclude *environment.conf.d/*vars.server.conf --exclude *environment.conf.d/*upstreams.http.conf --delete ${remote_config} /etc/api-gateway/"
      echo "   ... syncing from s3 using command ${sync_cmd}"
    else
      echo "   ... but this REMOTE_CONFIG is not supported "
    fi
fi

if [[ -n "${remote_config_sync_cmd}" ]]; then
    echo "   ... using REMOTE_CONFIG_SYNC_CMD: ${remote_config_sync_cmd}"
    echo ${remote_config_sync_cmd} > /tmp/remote_config_sync_cmd.sh
    sync_cmd="sh /tmp/remote_config_sync_cmd.sh"
fi

sudo -E api-gateway-config-supervisor \
        --reload-cmd="api-gateway -s reload" \
        --sync-folder=/etc/api-gateway \
        --sync-interval=${remote_config_sync_interval} \
        --sync-cmd="${sync_cmd}" \
        --http-addr=127.0.0.1:8888 &

if [[ -n "${marathon_host}" ]]; then
    echo "  ... starting Marathon Service Discovery on ${marathon_host}"
    touch /var/run/apigateway-config-watcher.lastrun
    # start marathon's service discovery
    while true; do sh /etc/api-gateway/marathon-service-discovery.sh > /dev/stderr; sleep ${sleep_duration}; done &
    # start simple statsd logger
    #
    # ASSUMPTION: there is a graphite app named "api-gateway-graphite" deployed in marathon
    #
    while true; do \
        statsd_host=$(curl -s ${marathon_host}/v2/apps/api-gateway-graphite/tasks -H "Accept:text/plain" | grep 8125 | awk '{for(i=3;i<=NF;++i) printf("%s ", $i) }' | awk '{for(i=1;i<=NF;++i) sub(/:[[:digit:]]+/,"",$i); print }' ); \
        if [[ -n "${statsd_host}" ]]; then python /etc/api-gateway/scripts/python/logger/StatsdLogger.py --statsd-host=${statsd_host} > /var/log/api-gateway/statsd-logger.log; fi; \
        sleep 6; \
    done &
fi

echo "   ... testing configuration "
sudo api-gateway -t -p /usr/local/api-gateway/ -c /etc/api-gateway/api-gateway.conf

echo "   ... starting prometheus exporter "
while true; do \
    status_code=$(curl -LI http://localhost/nginx_status -o /dev/null -w '%{http_code}\n' -s); \
    if [[ "${status_code}" == 200 ]]; then \
      sudo /etc/nginx-prometheus-exporter -nginx.scrape-uri http://localhost/nginx_status; \
    else \
      echo "   ... waiting for the nginx server to start "
      sleep 1; \
    fi; \
done &

echo "   ... using log level: '${log_level}'. Override it with -e 'LOG_LEVEL=<level>' "
sudo api-gateway -p /usr/local/api-gateway/ -c /etc/api-gateway/api-gateway.conf -g "daemon off; error_log /dev/stderr ${log_level}; env ACTIVE_ACTIVE=${active_active}; env ACTIVE_ACTIVE_API_GATEWAY_TOKEN=${active_active_api_gateway_token}; env ACTIVE_ACTIVE_SET_UPSTREAM_INTERVAL=${active_active_set_upstream_interval}; env ACTIVE_ACTIVE_STATUS_CHECK_INTERVAL=${active_active_status_check_interval}; env ACTIVE_ACTIVE_UPSTREAMS_CSV_PATH=${active_active_upstreams_csv_path};"
