#!/bin/bash
SCRIPT_PATH=$(dirname "$(readlink -e "$BASH_SOURCE")")
SCRIPT_NAME=$(basename "$BASH_SOURCE")
SERVICE_NAME="custom-routes"
echo "SCRIPT_PATH=$SCRIPT_PATH"
echo "SCRIPT_NAME=$SCRIPT_NAME"
echo "-------------------------------------------"
if [ "$SCRIPT_PATH" != "/usr/local/bin" ]; then
    cp $SCRIPT_PATH/$SCRIPT_NAME /usr/local/bin/$SCRIPT_NAME
    echo "Scrit copied to bin directory"
fi
chmod 755 /usr/local/bin/$SCRIPT_NAME
sleep 5
# Get a list of all interfaces except lo
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo')

isPrivateIP() {
    local ip=$1
    # Function of checking whether IP is included in the range of private addresses
    [[ $ip == 10.* || $ip == 172.1[6-9].* || $ip == 172.2[0-9].* || $ip == 172.3[0-1].* || $ip == 192.168.* ]]
}

for INTERFACE in $INTERFACES
do
echo "------------------------------------------ begin cycle------------------------------------------------"
echo ""
# Getting information about the interface

INTERFACE_IP=$(ip addr show dev $INTERFACE | grep -oP 'inet \K[\d.]+')

echo "IP address of interface  $INTERFACE is: $INTERFACE_IP"

# Extracting numbers from the interface name for the table number
TABLE_NUMBER=$(( $(echo $INTERFACE | tr -dc '0-9') + 1 ))
echo "Route table number is: $TABLE_NUMBER"

# Get the gateway from the interface in the main table
GATEWAY_IP=$(ip route show dev $INTERFACE | grep -i 'default via' | awk '{print $3}')

echo "Gateway_IP is: $GATEWAY_IP"

# Apply rules

RULE_EXISTS=$(ip rule | grep -q "$INTERFACE_IP lookup $TABLE_NUMBER" && echo "1" || echo "0")

echo "Rule_exist is: $RULE_EXISTS"

if [ $RULE_EXISTS -eq 0 ]; then
    ip rule add from $INTERFACE_IP lookup $TABLE_NUMBER
fi

# Create empty routing table with $TABLE_NUMBER 
ip route add table $TABLE_NUMBER  unreachable 5
ip route del table $TABLE_NUMBER  unreachable 5


ROUTE_EXISTS=$(ip route show table $TABLE_NUMBER | grep -q "default via $GATEWAY_IP" && echo "1" || echo "0")

if [ $ROUTE_EXISTS -eq 0 ]; then
    ip route add 0.0.0.0/0 via $GATEWAY_IP table $TABLE_NUMBER
fi

echo "Route exist is: $ROUTE_EXISTS"
echo "table of rules"
ip rule
echo  "routing table number $TABLE_NUMBER"
ip route show table $TABLE_NUMBER

# Remove the default rule for this interface from the main table
if isPrivateIP $INTERFACE_IP; then
        echo "$INTERFACE_IP is a private IP address. Deleting the default route for $INTERFACE."
        ip route del default dev $INTERFACE
    else
        echo "$INTERFACE_IP is a public IP address. Skipping route deletion."
        
    fi

done

#  Create  service of custom routes
#  Check existing service
if [ -e "/etc/systemd/system/$SERVICE_NAME.service" ]; then

    echo "Service $SERVICE_NAME is already configured."
else
    # create service systemd
    SERVICE_CONTENT="[Unit]
Description=Custom Routes Setup
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/$SCRIPT_NAME

[Install]
WantedBy=default.target
"
    echo "$SERVICE_CONTENT" | sudo tee "/etc/systemd/system/$SERVICE_NAME.service" > /dev/null

    # renew systemd
    sudo systemctl daemon-reload

    # enable autostart
    sudo systemctl enable $SERVICE_NAME

    # start service
    sudo systemctl start $SERVICE_NAME

    echo "Service $SERVICE_NAME has been created and started."
fi
