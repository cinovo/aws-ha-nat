#!/bin/bash

# aws-ha-nat
# 
# https://github.com/cinovo/aws-ha-nat
#
# Ben Lebherz (@benleb) / Tullius-Walden AG / Cinovo AG

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
#   http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


## in which environment are we?
environment="$1"
## which routing table should be modfied?
routingTable="$2"
## options for every aws cmd
awsCmdOpts="--region eu-west-1"

## ip-pools
poolEarly=("1.1.1.1" "2.2.2.2")
poolStage=("1.2.1.2" "2.1.2.1")
poolProd=("2.1.1.2" "1.2.2.1")

## ping options
numPings=3
pingTimeout=1
betweenPings=5


## log to stdout & syslog
function log() {
    logLevel=${2:-"notice"}; msg="natMonitor ($logLevel): $1"
    echo $msg; logger -p user.$logLevel $msg
}

## check for required arguments
[ "$#" -eq 2 ] || (log "2 arguments required, $# provided"; exit 1)

## get instance-id
instanceID=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/instance-id`
log "natMonitor started on $instanceID ($environment)"

## disable aws ip-source/dest check
log "disabling aws source/dest check..."
aws ec2 modify-instance-attribute --instance-id $instanceID --no-source-dest-check $awsCmdOpts
if [ $? != 0 ]; then
    log "disabling aws source/dest check failed! so working as nat-instance is not possible, killing me..." err
    aws ec2 terminate-instances --instance-ids $instanceID $awsCmdOpts
fi

## load ip-pool for desired env
case $environment in
    "early") elasticIPs=${poolEarly[*]};;
    "stage") elasticIPs=${poolStage[*]};;
    "prod") elasticIPs=${poolProd[*]};;
    *) log "no environment set, exiting!" err; exit 1;;
esac

## loop through ips to find a free one
for ip in ${elasticIPs[*]}; do
    ## check if ip is free
    log "checking $ip..."
    outLines=`aws ec2 describe-addresses --filters "Name=public-ip,Values=$ip" $awsCmdOpts | wc -l`
    if [ $outLines == 9 ]; then
        ## address seems not associated, get it
        allocationId=`aws ec2 describe-addresses --filters "Name=public-ip,Values=$ip" $awsCmdOpts | grep "AllocationId" | awk '{print $2}' | sed 's/^.//' | sed 's/.$//'`
        aws ec2 associate-address --instance-id $instanceID --allocation-id $allocationId $awsCmdOpts
        if [ $? == 0 ]; then
            log "associated ip address $ip to me ($instanceID)"
            elasticIP="$ip"
            break
        else
            log "associating ip address failed! help!!" err
            exit 1
        fi
    fi
done

## sleep until ip is really associated
sleep 10

## assert the correct elastic ip is associated
myPublicIP=`/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/public-ipv4`
if [ -z "$myPublicIP" ] || [ "$elasticIP" != "$myPublicIP" ]; then
    log "no or wrong public ip address ($myPublicIP != $elasticIP) associated to me, killing me"
    aws ec2 terminate-instances --instance-ids $instanceID $awsCmdOpts
    exit 1
fi

## get current active gateway
activeGW=`aws ec2 describe-route-tables --filters "Name=route-table-id,Values=$routingTable" $awsCmdOpts | grep "0.0.0.0/0" -A 2 | grep "InstanceId" | awk '{print $2}' | cut -c 2-11`
log "current active gw is $activeGW"

if [ "$instanceID" == "$activeGW" ]; then
    ## i am the gateway, nothing to do, exiting...
    log "everything seems fine, i am the default gateway"
    exit 0
else
    ## i am not the gateway, getting its ip...
    gatewayIP=`aws ec2 describe-instances --filters Name="instance-id,Values=$activeGW" $awsCmdOpts | grep "PublicIp" | head -n1 |  awk '{print $2}' | sed 's/^.//' | sed 's/..$//'`
    log "starting ping loop against the default gw ($gatewayIP)"

    ## take a break...
    sleep 3

    ## ping loop
    while [ . ]; do
        pingRes=`ping -c $numPings -W $pingTimeout $gatewayIP | grep time= | wc -l`
        if [ "$pingRes" == "0" ]; then
            ## ping failed, take over default route
            log "gateway ($gatewayIP) seems to be down, taking over the default route..." err
            aws ec2 replace-route --route-table-id $routingTable --destination-cidr-block "0.0.0.0/0" --instance-id $instanceID $awsCmdOpts
            if [ $? == 0 ]; then
                ## got the route, acting as default gw now, exiting script
                log "route set, now i am the default gateway in $routingTable, killing other instance ($activeGW)..."
                aws ec2 terminate-instances --instance-ids $activeGW $awsCmdOpts
                exit 0
            else
                log "setting route on $routingTable failed! trying again..." err
                sleep 3 # or exit?
            fi
        else
            echo "ping succeeded, lets take a nap (${betweenPings}s)..."
            sleep $betweenPings
        fi
    done
fi