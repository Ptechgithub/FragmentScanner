#!/bin/bash

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
white='\033[0;37m'
rest='\033[0m'

#!/bin/bash

if [ -n "$(command -v termux-chroot)" ] && [ -n "$(command -v jq)" ]; then
    echo "Running update & upgrade ..."
    pkg update -y
    pkg upgrade -y
fi

# Check and install necessary packages
install_packages() {
    local packages=(wget curl unzip jq)
    if [ -n "$(command -v pkg)" ]; then
        pkg install "${packages[@]}" -y
    elif [ -n "$(command -v apt)" ]; then
        sudo apt install "${packages[@]}" -y
    elif [ -n "$(command -v yum)" ]; then
        sudo yum install "${packages[@]}" -y
    elif [ -n "$(command -v dnf)" ]; then
        sudo dnf install "${packages[@]}" -y
    else
        echo -e "${red}Unsupported package manager. Please install required packages manually.${rest}"
        exit 1
    fi
}

# Download and install Xray if not already installed
if ! [ -x "$PREFIX/bin/xray" ]; then
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.13/Xray-android-arm64-v8a.zip
    unzip Xray-android-arm64-v8a.zip
    mv xray $PREFIX/bin
    rm README.md geoip.dat geosite.dat LICENSE Xray-android-arm64-v8a.zip

    if [ -x "$PREFIX/bin/xray" ]; then
        echo -e "${green}Xray installed successfully.${rest}"
    else
        echo -e "${red}Xray installation failed.${rest}"
        exit 1
    fi
else
    echo -e "${yellow}Xray is already installed.${rest}"
fi

# Fragment Scanner
fragment_scanner() {
    # Define paths for xray executable and configuration/log files
    XRAY_PATH="$PREFIX/bin/xray"
    CONFIG_PATH="config.json"
    LOG_FILE="pings.txt"
    XRAY_LOG_FILE="xraylogs.txt"

    # Check if xray executable exists
    if [ ! -f "$XRAY_PATH" ]; then
        echo "Error: xray not found"
        exit 1
    fi

    # Create log files if they do not exist
    [ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"
    [ ! -f "$XRAY_LOG_FILE" ] && touch "$XRAY_LOG_FILE"

    # Clear the content of the log files before running the tests
    > "$LOG_FILE"
    > "$XRAY_LOG_FILE"

    # Prompt user for input values with defaults
    echo -en "${green}Enter the number of instances (default is 10): ${rest}"
    read -r InstancesInput
    echo -e "${blue}*****************************${rest}"
    echo -en "${green}Enter the timeout for each ping test in seconds (default is 10): ${rest}"
    read -r TimeoutSecInput
    echo -e "${blue}*****************************${rest}"
    echo -en "${green}Enter the HTTP Listening port (default is 10809): ${rest}"
    read -r HTTP_PROXY_PORTInput
    echo -e "${blue}*****************************${rest}"
    echo -en "${green}Enter the number of requests per instance (default is 3): ${rest}"
    read -r PingCountInput
    echo -e "${blue}*****************************${rest}"

    # Set default values if inputs are empty
    Instances=${InstancesInput:-10}
    TimeoutSec=${TimeoutSecInput:-10}
    HTTP_PROXY_PORT=${HTTP_PROXY_PORTInput:-10809}
    PingCount=${PingCountInput:-3}

    # Increase PingCount by 1 to account for the extra request
    PingCount=$((PingCount + 1))

    # HTTP Proxy server address
    HTTP_PROXY_SERVER="127.0.0.1"

    # Arrays of possible values for packets, length, and interval
    packetsOptions=("tlshello" "1-1" "1-2" "1-3" "1-5")
    lengthOptions=("1-1" "1-2" "1-3" "2-5" "1-5" "1-10" "3-5" "5-10" "3-10" "10-15" "10-30" "10-20" "20-50" "50-100" "100-150")
    intervalOptions=("1-1" "1-2" "3-5" "1-5" "5-10" "10-15" "10-20" "20-30" "20-50" "40-50" "50-100" "50-80" "100-150" "150-200" "100-200")

    # Calculate the maximum possible instances
    maxPossibleInstances=$((${#packetsOptions[@]} * ${#lengthOptions[@]} * ${#intervalOptions[@]}))

    # Validate user input for instances against the maximum possible instances
    while [ "$Instances" -gt "$maxPossibleInstances" ]; do
        echo "Error: Number of instances cannot be greater than the maximum possible instances ($maxPossibleInstances)"
        read -p "Enter the number of instances (default is 10): " InstancesInput
        Instances=${InstancesInput:-10}
    done

    # Array to store top three lowest average response times
    declare -a topThree

    # Function to randomly select a value from an array
    get_random_value() {
        local options=("$@")
        echo "${options[RANDOM % ${#options[@]}]}"
    }

    # Function to generate a unique combination of packets, length, and interval values
    get_unique_combination() {
        local combination
        declare -A usedCombinations

        while true; do
            packets=$(get_random_value "${packetsOptions[@]}")
            length=$(get_random_value "${lengthOptions[@]}")
            interval=$(get_random_value "${intervalOptions[@]}")
            combination="$packets,$length,$interval"

            if [[ -z "${usedCombinations[$combination]}" ]]; then
                usedCombinations["$combination"]=1
                echo "$packets $length $interval"
                break
            fi
        done
    }

    # Function to modify config.json with random parameters
    modify_config() {
        local packets=$1
        local length=$2
        local interval=$3

        jq --arg packets "$packets" --arg length "$length" --arg interval "$interval" \
            '(.outbounds[] | select(.tag == "fragment") | .settings.fragment) |= {packets: $packets, length: $length, interval: $interval}' \
            "$CONFIG_PATH" > config.tmp && mv config.tmp "$CONFIG_PATH"
    }

    # Function to stop the Xray process
    stop_xray_process() {
        pkill -f xray
        sleep 1
        PIDs=$(pgrep -f xray)
        if [ -n "$PIDs" ]; then
            kill -9 $PIDs
        fi
    }

    # Function to perform HTTP requests with proxy and measure response time
    send_http_request() {
        local pingCount=$1
        local timeout=$((TimeoutSec * 1000))
        local url="http://cp.cloudflare.com"
        local totalTime=0
        local individualTimes=()

        for ((i=1; i<=pingCount; i++)); do
            local start=$(date +%s%3N)
            if curl -s -o /dev/null --max-time "$TimeoutSec" -x "$HTTP_PROXY_SERVER:$HTTP_PROXY_PORT" "$url"; then
                local end=$(date +%s%3N)
                local elapsed=$((end - start))
                totalTime=$((totalTime + elapsed))
                individualTimes+=("$elapsed")
            else
                individualTimes+=(-1)
                totalTime=$((totalTime + timeout))
            fi
            sleep 1
        done

        local validPings=()
        for t in "${individualTimes[@]}"; do
            if [ "$t" -ne -1 ]; then
                validPings+=("$t")
            fi
        done

        if [ "${#validPings[@]}" -gt 0 ]; then
            averagePing=$((totalTime / ${#validPings[@]}))
        else
            averagePing=0
        fi

        echo "Individual Ping Times: ${individualTimes[*]}" >> "$LOG_FILE"
        echo "$averagePing"
    }
    
    > "$LOG_FILE"
    > "$XRAY_LOG_FILE"

    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${rest}"
    echo -e "${cyan}|   Instance   |     Packets     |     Length    |     Interval    | Average Ping  |${rest}"
    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${cyan}"

    for ((i=0; i<Instances; i++)); do
        read packets length interval <<< "$(get_unique_combination)"
        modify_config "$packets" "$length" "$interval"
        stop_xray_process
        "$XRAY_PATH" -c "$CONFIG_PATH" &> "$XRAY_LOG_FILE" &
        sleep 3

        echo "Testing with packets=$packets, length=$length, interval=$interval..." >> "$LOG_FILE"
        averagePing=$(send_http_request "$PingCount")
        echo "Average Ping Time: $averagePing ms" >> "$LOG_FILE"

        topThree+=("$((i + 1)),$packets,$length,$interval,$averagePing")

        printf "|      %-4s    |       %-8s  |      %-7s  |      %-7s    |      %-5s    |\n" "$((i + 1))" "$packets" "$length" "$interval" "$averagePing"
        sleep 1
    done

    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${rest}"

    validResults=()
    for result in "${topThree[@]}"; do
        IFS=',' read -r -a arr <<< "$result"
        if [ "${arr[4]}" -gt 0 ]; then
            validResults+=("$result")
        fi
    done

    IFS=$'\n' sortedTopThree=($(sort -t, -k5 -n <<<"${validResults[*]}"))
    unset IFS
    echo ""
    echo -e "${green}Top three lowest average response times:${rest}"
    echo -e "${blue}******************************************${rest}"
    for result in "${sortedTopThree[@]:0:3}"; do
        IFS=',' read -r -a arr <<< "$result"
        printf "| Instance: %s | Packets: %s | Length: %s | Interval: %s | AverageResponseTime (ms): %s |\n" "${arr[0]}" "${arr[1]}" "${arr[2]}" "${arr[3]}" "${arr[4]}"
    done

    stop_xray_process
    echo -e "${blue}*****************************${rest}"
    echo -en "${green}Press Enter to exit the script...${rest}"
    read -r
}

# ADD FRAGMENT TO CONFIG
config2Fragment() {
    # Prompt user for input
    echo -en "${green}Enter your Config [${yellow}VLESS${cyan}/${yellow}VMESS${cyan}/${yellow}TROJAN${green}][${yellow}Ws${cyan}/${yellow}Grpc${green}]: ${rest}"
    read -r link

    # Initialize variables
    protocol=""
    network=""
    address=""
    port=""
    uuid=""
    path=""
    security=""
    encryption=""
    host=""
    fp=""
    conn_type=""
    sni=""
    name=""
    pass=""
    tls=""
    serviceName=""

    # Decode & parse VMess configuration
    vmess() {
        link=${link#"vmess://"}
        vmess_config=$(echo "$link" | base64 -d 2>/dev/null)
        
        address=$(echo "$vmess_config" | jq -r '.add')
        port=$(echo "$vmess_config" | jq -r '.port')
        uuid=$(echo "$vmess_config" | jq -r '.id')
        path=$(echo "$vmess_config" | jq -r '.path')
        network=$(echo "$vmess_config" | jq -r '.net')
        security=$(echo "$vmess_config" | jq -r '.scy')
        host=$(echo "$vmess_config" | jq -r '.host')
        type=$(echo "$vmess_config" | jq -r '.type')
        fp=$(echo "$vmess_config" | jq -r '.fp')
        tls=$(echo "$vmess_config" | jq -r '.tls')
        sni=$(echo "$vmess_config" | jq -r '.sni')
        name=$(echo "$vmess_config" | jq -r '.ps')
        protocol="vmess"
        if [[ $type == "multi" ]]; then
            multiMode="true"
        else
            multiMode="false"
        fi
    }

    # Decode and parse VLESS configuration
    vless() {
        uuid=$(echo "$link" | sed -n 's|^vless://\([a-z0-9\-]*\)@.*|\1|p')
        address=$(echo "$link" | sed -n 's|^vless://[a-z0-9\-]*@\([0-9a-zA-Z.]*\):.*|\1|p')
        port=$(echo "$link" | sed -n 's|^vless://[a-z0-9\-]*@[0-9a-zA-Z.]*:\([0-9]*\).*|\1|p')
        path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
        encryption=$(echo "$link" | sed -n 's|.*encryption=\([^&]*\).*|\1|p')
        host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
        fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
        conn_type=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p')
        sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
        name=$(echo "$link" | sed -n 's|.*#\([^#]*\)$|\1|p')
        network=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p')
        serviceName=$(echo "$link" | sed -n 's|.*serviceName=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        protocol="vless"
        if [[ $link == *"mode=multi"* ]]; then
            multiMode="true"
        else
            multiMode="false"
        fi
    }

    # Decode & parse Trojan configuration
    trojan() {
        pass=$(echo "$link" | sed -n 's|^trojan://\([^@]*\)@.*|\1|p')
        address=$(echo "$link" | sed -n 's|^trojan://[^@]*@\([^:]*\):.*|\1|p')
        port=$(echo "$link" | sed -n 's|^trojan://[^@]*@[^:]*:\([^?]*\).*|\1|p')
        path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
        host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
        fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
        conn_type=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p' | sed 's|#.*||')
        sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
        name=$(echo "$link" | sed 's|^.*#||')
        network=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p')
        protocol="trojan"
        if [[ $link == *"mode=multi"* ]]; then
            multiMode="true"
        else
            multiMode="false"
        fi
    }

    # Determine protocol and parse configuration
    if [[ $link == "vmess://"* ]]; then
        vmess
    elif [[ $link == "vless://"* ]]; then
        vless
    elif [[ $link == "trojan://"* ]]; then
        trojan
     else
         echo -e "${red}Unsupported link.${rest}"
         exit 1
         
    fi

    json=$(cat <<EOF
{
  "remarks": "$name+Fragment",
  "log": {
    "access": "",
    "error": "",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true,
        "allowTransparent": false
      }
    },
    {
      "tag": "http",
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "http",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true,
        "allowTransparent": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "$protocol",
      "settings": {
      
EOF
    )

    # Outbound
    if [[ $protocol == "vmess" || $protocol == "vless" ]]; then
        json+=$(cat <<EOF
  "vnext": [
          {
            "address": "$address",
            "port": $port,
            "users": [
              {
                "id": "$uuid",
                "alterId": 0,
                "email": "email",
                "security": "auto",
                "encryption": "none",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$network",
      
EOF
        )
    fi

    #Add Trojan settings
    if [[ $protocol == "trojan" ]]; then
        json+=$(cat <<EOF
  "servers": [
          {
            "address": "$address",
            "level": 1,
            "flow": "",
            "method": "chacha20-poly1305",
            "ota": false,
            "password": "$pass",
            "port": $port
          }
        ]
      },
      "streamSettings": {
        "network": "$network",
        
EOF
        )
    fi

    # Tls
    if [[ $tls == "tls" || $security == "tls" ]]; then
        json+=$(cat <<EOF
  "security": "tls",
        "tlsSettings": {
          "allowInsecure": false,
          "serverName": "$sni",
          "alpn": [
            "h2",
            "http/1.1"
          ],
          "fingerprint": "chrome",
          "show": false
        },
        
EOF
        )
    fi

    # Add GRPC settings if network is grpc
    if [[ $network == "grpc" ]]; then
        json+=$(cat <<EOF
"grpcSettings": {
          "multiMode": $multiMode,
          "serviceName": "$serviceName"
        },
        
EOF
        )
    fi

    # Add websocket settings for VMess and VLESS WS
    if [[ $network == "ws" ]]; then
        json+=$(cat <<EOF
  "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
        
EOF
        )
    fi

    if [[ $tls == "tls" || $security == "tls" ]]; then
        json+=$(cat <<EOF
"sockopt": {
          "dialerProxy": "fragment",
          "tcpKeepAliveIdle": 100,
          "mark": 255,
          "tcpNoDelay": true
        }
      }
    },
    {
      "tag": "fragment",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs",
        "fragment": {
          "packets": "tlshello",
          "length": "10-20",
          "interval": "10-20"
        }
      },
      
EOF
        )
    else
        json+=$(cat <<EOF
"sockopt": {
          "dialerProxy": "fragment",
          "tcpKeepAliveIdle": 100,
          "mark": 255,
          "tcpNoDelay": true
        }
      }
    },
    {
      "tag": "fragment",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "AsIs",
        "fragment": {
          "packets": "1-1",
          "length": "1-3",
          "interval": "5"
        }
      },
      
EOF
        )
    fi

    # Complete streamSettings
    json+=$(cat <<EOF
"streamSettings": {
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveIdle": 100
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "enabled": true
      },
      {
        "id": "5627785659655799759",
        "type": "field",
        "port": "0-65535",
        "outboundTag": "proxy",
        "enabled": true
      }
    ]
  }
}
EOF
    )

    echo "$json" > config.json
    echo -e "${yellow}==========================${rest}"
    echo -e "${yellow}==========================${rest}"
    cat config.json
    echo -e "${yellow}===============================${rest}"
    echo -e "${green}Config saved in ${yellow}config.json ${green}file${rest}"
    echo -e "${yellow}==========================${rest}"
}

# Main menu
install_packages
clear
echo -e "${cyan}By --> Peyman * Github.com/Ptechgithub * ${rest}"
echo ""
echo -e "${yellow}************************${rest}"
echo -e "${yellow}*    ${purple}Fragment Tools${yellow}    *${rest}"
echo -e "${yellow}************************${rest}"
echo -e "${yellow}[${green}1${yellow}] ${green}Config To fragment${yellow} * ${rest}"
echo -e "${yellow}                       *${rest}"
echo -e "${yellow}[${green}2${yellow}] ${green}Fragment Scanner${yellow}   * ${rest}"
echo -e "${yellow}                       *${rest}"
echo -e "${yellow}[${red}0${yellow}] Exit               *${rest}"
echo -e "${yellow}************************${rest}"
echo -en "${cyan}Enter your choice: ${rest}"
read -r choice
case "$choice" in
    1)
        echo -e "${yellow}************************${rest}"
        config2Fragment
        ;;
    2)
        echo -e "${yellow}************************${rest}"
        fragment_scanner
        ;;
    0)
        echo -e "${yellow}************************${rest}"
        echo -e "${cyan}Goodbye!${rest}"
        exit
        ;;
    *)
        echo -e "${yellow}********************${rest}"
        echo -e "${red}Invalid choice. Please select a valid option.${rest}"
        ;;
esac