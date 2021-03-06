#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2015, Joyent, Inc.
#

#
# Setup your environment for `docker` to use a SmartDataCenter Docker.
#
# The basic steps are:
#
# 1. Select the data center (i.e. the Cloud API URL).
# 2. Select the account (login) to use.
# 3. Ensure the account has an SSH key to use.
# 4. Generate a client certificate from your SSH key and save that where
#    `docker` can use it: "~/.sdc/docker/$account/".
#

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi
set -o errexit
set -o pipefail

# ---- globals

NAME=$(basename $0)
VERSION=1.0.0

CERT_BASE_DIR=$HOME/.sdc/docker

CURL_OPTS=" -H user-agent:sdc-docker-setup/$VERSION"


# ---- support functions

function fatal
{
    echo "" >&2
    echo "* * *" >&2
    echo "$NAME: fatal error: $*" >&2
    exit 1
}

function warn
{
    echo "$NAME: warn: $*" >&2
}

function usage
{
    echo "Usage:"
    echo "  sdc-setup-docker [SDC-CLOUDAPI-OR-REGION] [ACCOUNT] [SSH-PRIVATE-KEY-PATH]"
    echo ""
    echo "Options:"
    echo "  -h      Print this help and exit."
    echo "  -V      Print version and exit."
    echo "  -f      Force setup without checks (check that the given login and"
    echo "          ssh key exist in the SDC cloudapi, check that the Docker"
    echo "          hostname responds, etc)."
    echo "  -k      Disable SSH certificate verification (e.g. if using CoaL"
    echo "          for development)."
    # TODO: examples
}

function debug
{
    #echo "$NAME: debug: $@" >&2
    true
}

function dockerInfo
{
    local dockerUrl response
    dockerUrl=$1

    local curlOpts
    if [[ $optInsecure == "true" ]]; then
        curlOpts=" -k"
    fi
    curl $CURL_OPTS -sSf $curlOpts --connect-timeout 10 \
        --url $dockerUrl/v1.16/info
}


function cloudapiVerifyAccount() {
    local cloudapiUrl account sshPrivKeyPath sshKeyId now signature response
    cloudapiUrl=$1
    account=$2
    sshPrivKeyPath=$3
    sshKeyId=$4

    now=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    signature=$(echo ${now} | tr -d '\n' | openssl dgst -sha256 -sign $sshPrivKeyPath | openssl enc -e -a | tr -d '\n')

    local curlOpts
    if [[ $coal == "true" || $optInsecure == "true" ]]; then
        curlOpts=" -k"
    fi

    local response status
    response=$(curl $CURL_OPTS $curlOpts -isS \
        -H "Accept:application/json" -H "api-version:*" -H "Date: ${now}" \
        -H "Authorization: Signature keyId=\"/$account/keys/$sshKeyId\",algorithm=\"rsa-sha256\" ${signature}" \
        --url $cloudapiUrl/--ping)
    status=$(echo "$response" | head -1 | awk '{print $2}')
    case "$status" in
        401)
            if [[ -n "$portalUrl" ]]; then
                fatal "invalid credentials" \
                    "\nVisit <$portalUrl> to create the '$account' account" \
                    "\nand/or add your SSH public key ($sshPubKeyPath)"
            elif [[ "$coal" == "true" ]]; then
                fatal "invalid credentials" \
                    "\n    You must add create the '$account' account and/or add your SSH" \
                    "\n    public key ($sshPubKeyPath) to the" \
                    "\n    given SmartDataCenter."\
                    "\n" \
                    "\n    On CoaL you can do this via:" \
                    "\n        scp $sshPubKeyPath root@10.99.99.7:/var/tmp/id_rsa.pub" \
                    "\n        ssh root@10.99.99.7" \
                    "\n        sdc-useradm get $account >/dev/null 2>/dev/null || \\" \
                    "\n            echo '{\"login\":\"$account\",\"userpassword\":\"secret123\",\"cn\":\"$account Test User\",\"email\":\"$account@example.com\"}' | sdc-useradm create -A" \
                    "\n        sdc-useradm add-key $account /var/tmp/id_rsa.pub"
            else
                fatal "invalid credentials" \
                    "\n    You must add create the '$account' account and/or add your SSH" \
                    "\n    public key ($sshPubKeyPath) to the" \
                    "\n    given SmartDataCenter."
            fi
            ;;
        200)
            echo "Credentials are valid."
            ;;
        *)
            if [[ "$status" == "400" && "$coal" == "true" ]]; then
                fatal "'Bad Request' from cloudapi. Possibly clock skew. Otherwise, check the cloudapi log.\n\n$response"
            fi
            fatal "Unexpected cloudapi response:\n\n$response"
            ;;
    esac
}


function cloudapiGetDockerService() {
    local cloudapiUrl account sshPrivKeyPath sshKeyId now signature response
    cloudapiUrl=$1
    account=$2
    sshPrivKeyPath=$3
    sshKeyId=$4

    # TODO: share the 'cloudapi request' code
    now=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    signature=$(echo ${now} | tr -d '\n' | openssl dgst -sha256 -sign $sshPrivKeyPath | openssl enc -e -a | tr -d '\n')

    local curlOpts
    if [[ $coal == "true" || $optInsecure == "true" ]]; then
        curlOpts=" -k"
    fi

    # TODO: a test on ListServices being a single line of JSON
    local response status dockerService
    response=$(curl $CURL_OPTS $curlOpts -isS \
        -H "Accept:application/json" -H "api-version:*" -H "Date: ${now}" \
        -H "Authorization: Signature keyId=\"/$account/keys/$sshKeyId\",algorithm=\"rsa-sha256\" ${signature}" \
        --url $cloudapiUrl/$account/services)
    status=$(echo "$response" | head -1 | awk '{print $2}')
    if [[ "$status" != "200" ]]; then
        warn "could not get Docker service endpoint from cloudapi (status=$status)"
        return
    fi
    dockerService=$(echo "$response" | tail -1 | sed -E 's/.*"docker":"([^"]*)".*/\1/')
    if [[ "$dockerService" != "$response" ]]; then
        echo $dockerService
    fi
}



# ---- mainline

optForce=
optInsecure=
while getopts "hVfk" opt; do
    case "$opt" in
        h)
            usage
            exit 0
            ;;
        V)
            echo "$(basename $0) $VERSION"
            exit 0
            ;;
        f)
            optForce=true
            ;;
        k)
            optInsecure=true
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))


# Get the cloudapi URL. Default to the cloudapi for the current pre-release
# docker service. Eventually can default to the user's SDC_URL setting.
#
# Offer some shortcuts:
# - coal: Find the cloudapi in your local CoaL via ssh.
# - <string without dots>: Treat as a Joyent Cloud region name and use:
#       https://$dc.api.joyent.com
# - if given without 'https://' prefix: add that automatically
promptedUser=
cloudapiUrl=$1
if [[ -z "$cloudapiUrl" ]]; then
    defaultCloudapiUrl=https://us-east-3b.api.joyent.com
    #echo "Enter the SDC Docker hostname. Press enter for the default."
    printf "SDC Cloud API URL [$defaultCloudapiUrl]: "
    read cloudapiUrl
    promptedUser=true
fi
if [[ -z "$cloudapiUrl" ]]; then
    portalUrl=https://my.joyent.com
    cloudapiUrl=$defaultCloudapiUrl
elif [[ "$cloudapiUrl" == "coal" ]]; then
    coal=true
    cloudapiUrl=https://$(ssh -o ConnectTimeout=5 root@10.99.99.7 "vmadm lookup -j alias=cloudapi0 | json -ae 'ext = this.nics.filter(function (nic) { return nic.nic_tag === \"external\"; })[0]; this.ip = ext ? ext.ip : this.nics[0].ip;' ip")
    if [[ -z "$cloudapiUrl" ]]; then
        fatal "could not find the cloudapi0 zone IP in CoaL"
    fi
elif [[ "${cloudapiUrl/./X}" == "$cloudapiUrl" ]]; then
    portalUrl=https://my.joyent.com
    cloudapiUrl=https://$cloudapiUrl.api.joyent.com
elif [[ "${cloudapiUrl:0:8}" != "https://" ]]; then
    cloudapiUrl=https://$cloudapiUrl
fi
debug "cloudapiUrl: $cloudapiUrl"


# Get the account to use.
account=$2
if [[ -z "$account" ]]; then
    defaultAccount=$SDC_ACCOUNT
    if [[ -z "$defaultAccount" ]]; then
        printf "SDC Account: "
    else
        printf "SDC Account [$defaultAccount]: "
    fi
    read account
    promptedUser=true
fi
if [[ -z "$account" && -n "$defaultAccount" ]]; then
    account=$defaultAccount
fi
debug "account: $account"
if [[ -z "$account" ]]; then
    fatal "no account (login name) was given"
fi


# Get SSH priv key path.
sshPrivKeyPath=$3
if [[ -z "$sshPrivKeyPath" ]]; then
    # TODO: Using SDC_KEY_ID and search ~/.ssh for a matching key.
    if [[ -f $HOME/.ssh/id_rsa ]]; then
        defaultSSHPrivKeyPath=$HOME/.ssh/id_rsa
    fi
    if [[ -z "$defaultSSHPrivKeyPath" ]]; then
        printf "SSH private key path: "
    else
        printf "SDC Account [$defaultSSHPrivKeyPath]: "
    fi
    read sshPrivKeyPath
    promptedUser=true
fi
if [[ -z "$sshPrivKeyPath" && -n "$defaultSSHPrivKeyPath" ]]; then
    sshPrivKeyPath=$defaultSSHPrivKeyPath
fi
sshPrivKeyPath=$(bash -c "echo $sshPrivKeyPath")    # resolve '~'
if [[ ! -f $sshPrivKeyPath ]]; then
    fatal "'$sshPrivKeyPath' does not exist"
fi
debug "sshPrivKeyPath: $sshPrivKeyPath"
if [[ -z "$sshPrivKeyPath" ]]; then
    fatal "no SSH private key path was given"
fi


[[ $promptedUser == "true" ]] && echo ""
echo "Setting up for SDC Docker using:"
echo "    Cloud API:       $cloudapiUrl"
echo "    Account:         $account"
echo "    SSH private key: $sshPrivKeyPath"
echo ""


if [[ $optForce != "true" ]]; then
    sshPubKeyPath=$sshPrivKeyPath.pub
    if [[ ! -f $sshPubKeyPath ]]; then
        fatal "could not verify account/key: SSH public key does not exist at '$sshPubKeyPath'"
    fi
    sshKeyId=$(ssh-keygen -l -f $sshPubKeyPath | awk '{print $2}' | tr -d '\n')
    debug "sshKeyId: $sshKeyId"

    echo "Verifying credentials."
    cloudapiVerifyAccount "$cloudapiUrl" "$account" "$sshPrivKeyPath" "$sshKeyId"
fi


echo "Generating client certificate from SSH private key."
certDir="$CERT_BASE_DIR/$account"
keyPath=$certDir/key.pem
certPath=$certDir/cert.pem
csrPath=$certDir/csr.pem

mkdir -p $(dirname $keyPath)
openssl rsa -in $sshPrivKeyPath -outform pem > $keyPath
openssl req -new -key $keyPath -out $csrPath -subj "/CN=$account" >/dev/null 2>/dev/null
# TODO: expiry?
openssl x509 -req -days 365 -in $csrPath -signkey $keyPath -out $certPath >/dev/null 2>/dev/null
echo "Wrote certificate files to $certDir"


echo "Get Docker host endpoint from cloudapi."
dockerService=$(cloudapiGetDockerService "$cloudapiUrl" "$account" "$sshPrivKeyPath" "$sshKeyId")
if [[ -n "$dockerService" ]]; then
    echo "Docker service endpoint is: $dockerService"
else
    echo "Could not discover service endpoint for DOCKER_HOST from cloudapi"
fi


echo ""
echo "* * *"
echo "Successfully setup for SDC Docker. Set your environment as follows: "
echo ""
echo "    export DOCKER_CERT_PATH=$certDir"
if [[ -n "$dockerService" ]]; then
    echo "    export DOCKER_HOST=$dockerService"
else
    echo "    # See the product documentation for the Docker host."
    echo "    export DOCKER_HOST=tcp://<HOST>:2376"
fi
echo "    alias docker=\"docker --tls\""
echo ""
echo "Then you should be able to run 'docker info' and you see your account"
echo "name 'SDCAccount' in the output."
