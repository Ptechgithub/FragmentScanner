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

# Check and install necessary packages
if ! command -v wget &> /dev/null; then
    echo "${green}installing wget...${rest}"
    pkg update -y
    pkg upgrade -y
    pkg install wget -y
fi

if ! command -v curl &> /dev/null; then
    echo "${green}installing curl...${rest}"
    pkg install curl -y
fi

if ! command -v unzip &> /dev/null; then
    echo "${green}installing unzip...${rest}"
    pkg install unzip -y
fi

if ! command -v jq &> /dev/null; then
    echo "${green}installing jq...${rest}"
    pkg install jq -y
fi

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
    CONFIG_PATH="$HOME/config.json"
    LOG_FILE="$HOME/pings.txt"
    XRAY_LOG_FILE="$HOME/xraylogs.txt"

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
    packetsOptions=("1-1" "1-2" "1-3" "1-5")
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
	echo -en "${green}Enter your Config: ${rest}"
    read -r link
	
	# VMESS
	if [[ $link == "vmess://"* ]]; then
	    # Remove "vmess://" from the beginning
	    link=${link#"vmess://"}
	    vmess_config=$(echo "$link" | base64 -d 2>/dev/null)
	    if [ -z "$vmess_config" ]; then
	        echo "Invalid VMess link."
	        exit 1
	    fi
		
		# Parse the VMess config using jq
		address=$(echo "$vmess_config" | jq -r '.add')
		port=$(echo "$vmess_config" | jq -r '.port')
		uuid=$(echo "$vmess_config" | jq -r '.id')
		path=$(echo "$vmess_config" | jq -r '.path')
		network=$(echo "$vmess_config" | jq -r '.net')
		security=$(echo "$vmess_config" | jq -r '.scy')
		host=$(echo "$vmess_config" | jq -r '.host')
		fp=$(echo "$vmess_config" | jq -r '.fp')
		tls=$(echo "$vmess_config" | jq -r '.tls')
		sni=$(echo "$vmess_config" | jq -r '.sni')
		name=$(echo "$vmess_config" | jq -r '.ps')
		alpn=$(echo "$vmess_config" | jq -r '.alpn')
		
		# Check if ALPN is not null or empty
	    if [ "$alpn" != "null" ] && [ -n "$alpn" ]; then
	        alpn=$(echo "$alpn" | jq -r 'split(",") | map("\"" + . + "\"") | join(",\n")')
	    else
	        alpn=""
	    fi
		
		# Check if TLS is provided in the VMess config
		if [ "$tls" == "tls" ]; then
		    # Create the JSON config with TLS
		    json=$(cat <<EOF
	{
	  "remarks": "$name+TLS+Fragment",
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
	      "protocol": "vmess",
	      "settings": {
	        "vnext": [
	          {
	            "address": "$address",
	            "port": $port,
	            "users": [
	              {
	                "id": "$uuid",
	                "alterId": 0,
	                "email": "email",
	                "security": "$security",
	                "encryption": "none",
	                "flow": ""
	              }
	            ]
	          }
	        ]
	      },
	      "streamSettings": {
	        "network": "$network",
	        "security": "tls",
	        "tlsSettings": {
	          "allowInsecure": false,
	          "serverName": "$sni",
	          "alpn": [
	            $alpn
	          ],
	          "fingerprint": "$fp",
	          "show": false
	        },
	        "wsSettings": {
	          "path": "$path",
	          "headers": {
	            "Host": "$host"
	          }
	        },
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
	    else
	        # VMESS NO TLS
	        json=$(cat <<EOF
{
  "remarks": "$name+NoTls+Fragment",
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
      "protocol": "vmess",
      "settings": {
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
        "network": "ws",
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
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
	    fi
	    
		echo "$json" | jq . > config.json
		echo -e "${purple}************************${rest}"
		echo -e "${green}Configuration saved to config.json${rest}"
	
	#===================================
	
	# VLESS
	elif [[ $link == "vless://"* ]]; then
	    # Parse the VLESS link
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
		alpn=$(echo "$link" | sed -n 's|.*alpn=\([^&]*\).*|\1|p' | sed 's|,|","|g')
	    
	    if [ "$alpn" != "null" ] && [ -n "$alpn" ]; then
		    alpn="\"$alpn\""
		else
		    alpn=""
		fi
		
	    # VLESS TLS
		if [ "$security" == "tls" ]; then
	        # Create the JSON config
	        json=$(cat <<EOF
{
  "remarks": "$name+TLS+Fragment",
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
      "protocol": "vless",
      "settings": {
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
                "encryption": "$encryption",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$conn_type",
        "security": "$security",
        "tlsSettings": {
          "allowInsecure": false,
          "serverName": "$sni",
          "alpn": [
            $alpn
          ],
          "fingerprint": "$fp",
          "show": false
        },
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
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
	    else
			# VLESS NO TLS
			uuid=$(echo "$link" | sed -n 's|^vless://\([a-z0-9\-]*\)@.*|\1|p')
			address=$(echo "$link" | sed -n 's|^vless://[a-z0-9\-]*@\([0-9a-zA-Z.-]*\):.*|\1|p')
			port=$(echo "$link" | sed -n 's|^vless://[a-z0-9\-]*@[0-9a-zA-Z.-]*:\([0-9]*\).*|\1|p')
			path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
			encryption=$(echo "$link" | sed -n 's|.*encryption=\([^&]*\).*|\1|p')
			host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
			conn_type=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p' | sed 's|#.*||')
			
			json=$(cat <<EOF
{
  "remarks": "$name+NoTls+Fragment",
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
      "protocol": "vless",
      "settings": {
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
                "encryption": "$encryption",
                "flow": ""
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$conn_type",
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
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
	    fi
	
		echo "$json" | jq . > config.json
		echo -e "${purple}************************${rest}"
		echo -e "${green}Configuration saved to config.json${rest}"
	
	#===================================
	elif [[ $link == "trojan://"* ]]; then
	    
	    # Extract parameters using sed
		pass=$(echo "$link" | sed -n 's|^trojan://\([^@]*\)@.*|\1|p')
		address=$(echo "$link" | sed -n 's|^trojan://[^@]*@\([^:]*\):.*|\1|p')
		port=$(echo "$link" | sed -n 's|^trojan://[^@]*@[^:]*:\([^?]*\).*|\1|p')
		path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
		security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
		alpn=$(echo "$link" | grep -oP '(?<=alpn=)[^&]+' | tr ',' '\n' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$/\n/')
		host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
		fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
		conn_type=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p' | sed 's|#.*||')
		sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
		name=$(echo "$link" | sed 's|^.*#||')
		
		if [ "$security" == "tls" ]; then
			# Build the JSON configuration
			json=$(cat <<EOF
{
  "remarks": "$name+TLS+Fragment",
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
      "protocol": "trojan",
      "settings": {
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
        "network": "$conn_type",
        "security": "$security",
        "tlsSettings": {
          "allowInsecure": false,
          "serverName": "$sni",
          "alpn": [
              $alpn
          ],
          "fingerprint": "$fp",
          "show": false
        },
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
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
	    else
			# Extract parameters using sed
			pass=$(echo "$link" | sed -n 's|^trojan://\([a-zA-Z0-9]*\)@.*|\1|p')
			address=$(echo "$link" | sed -n 's|^trojan://[a-zA-Z0-9]*@\([0-9a-zA-Z.-]*\):.*|\1|p')
			port=$(echo "$link" | sed -n 's|^trojan://[a-zA-Z0-9]*@[0-9a-zA-Z.-]*:\([0-9]*\).*|\1|p')
			path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
			security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
			host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
			fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
			conn_type=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p' | sed 's|#.*||')
			sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
			name=$(echo "$link" | sed 's|^.*#||')
			
			# TROJAN NO TLS
			json=$(cat <<EOF
{
  "remarks": "$name+NoTls+Fragment",
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
      "protocol": "trojan",
      "settings": {
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
        "network": "$conn_type",
        "wsSettings": {
          "path": "$path",
          "headers": {
            "Host": "$host"
          }
        },
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
	    fi
	
	    echo "$json" | jq . > config.json
	    echo -e "${purple}************************${rest}"
		echo -e "${green}Configuration saved to config.json${rest}"
	
	else
	    echo -e "${red}Unsupported Config type.${rest}"
	    exit 1
	fi
}

# Main menu
clear
echo -e "${cyan}By --> Peyman * Github.com/Ptechgithub * ${rest}"
echo ""
echo -e "${purple}************************${rest}"
echo -e "${purple}*    ${green}Fragment Tools${purple}    *${rest}"
echo -e "${purple}************************${rest}"
echo -e "${purple}[1] ${blue}Config To fragment${purple} * ${rest}"
echo -e "${purple}                       *${rest}"
echo -e "${purple}[2] ${blue}Fragment Scanner${purple}   * ${rest}"
echo -e "${purple}                       *${rest}"
echo -e "${purple}[${red}0${purple}] Exit               *${rest}"
echo -e "${purple}************************${rest}"
echo -en "${cyan}Enter your choice: ${rest}"
read -r choice
case "$choice" in
    1)
        echo -e "${purple}************************${rest}"
        config2Fragment
        ;;
    2)
        echo -e "${purple}************************${rest}"
        fragment_scanner
        ;;
    0)
        echo -e "${purple}************************${rest}"
        echo -e "${cyan}Goodbye!${rest}"
        exit
        ;;
    *)
        echo -e "${yellow}********************${rest}"
        echo -e "${red}Invalid choice. Please select a valid option.${rest}"
        ;;
esac