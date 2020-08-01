#!/bin/bash
set -euo pipefail

# MAKE SURE LOCAL HOSTNAME IS BOTH SET VIA hostnamectl AND PRESENT AS 127.0.1.1 IN /etc/hosts
# MAKE SURE TO dpkg-reconfigure locales to en-US.UTF-8!

ID="$(cat /opt/cdn-id)"

cd "$(dirname "$0")"

addIfMissing() {
    if ! grep -qF "$2" "$1"
    then
        echo "$2" >> "$1"
    fi
}


apt-get -y install pdns-server pdns-backend-bind nginx python3 python3-acme python3-boto3 python3-josepy python3-jinja2 python3-crypto bird apparmor-utils sudo git gcc libfuse-dev fuse bind9utils software-properties-common

sed -i "s~__SERVER_ID__~$ID~" ./config.yml

enableStart() {
    systemctl enable "$1"
    systemctl restart "$1"
}

printf "$ID * * * * python3 /opt/cdn/certifier --cron\n@reboot bash /opt/cdn/configurator/out/ips.sh\n" | crontab

rm -rf certifier/dnssec
ln -sf /etc/powerdns/dnssec certifier/dnssec
mkdir -p /etc/powerdns/sites /var/www/empty /var/www/sites /etc/powerdns/dnssec /etc/nginx/includes /mnt/certifier/keys /mnt/certifier/certs
chown pdns:pdns /etc/powerdns/dnssec /opt/cdn/certifier/dnssec
chmod 700 /etc/powerdns/dnssec /opt/cdn /mnt/certifier /mnt/certifier/* || true
chmod 600 /opt/cdn/config.yml

if [ ! -f /var/lib/powerdns/bind-dnssec.db ]
then
    pdnsutil create-bind-db /var/lib/powerdns/bind-dnssec.db
fi
chown pdns:pdns /var/lib/powerdns/bind-dnssec.db

cp files/pdns.conf /etc/powerdns/pdns.d/custom.conf

enableStart bird
enableStart bird6
enableStart pdns || true
enableStart nginx

if [ ! -f /etc/ssl/default.crt ]
then
    openssl req -newkey rsa:4096 -nodes -keyout /etc/ssl/default.key -x509 -days 1 -out /etc/ssl/default.crt -subj '/CN=invalid.pawnode.com'
fi

# FALLBACKFS
if [ ! -d /opt/deffs ]
then
    git clone https://github.com/Doridian/deffs /opt/deffs
fi
gcc -O2 -D_FILE_OFFSET_BITS=64 /opt/deffs/main.c -lfuse -o /usr/bin/deffs

addIfMissing /etc/fstab 'deffs#/opt/cdn/certifier/certs /mnt/certifier/certs fuse defaults,nonempty,deffile=/etc/ssl/default.crt 0 0'
addIfMissing /etc/fstab 'deffs#/opt/cdn/certifier/keys /mnt/certifier/keys fuse defaults,nonempty,deffile=/etc/ssl/default.key 0 0'
mount -a
# END FALLBACKS

# WIREGUARD
add-apt-repository -y ppa:wireguard/wireguard
apt -y install wireguard
if [ ! -f /etc/wireguard/keys ]
then
    mkdir -p /etc/wireguard/keys
    wg genkey | tee /etc/wireguard/keys/private | wg pubkey > /etc/wireguard/keys/public
    chmod 600 /etc/wireguard/keys/private
fi
sysctl -w net.ipv4.ip_forward=1
# END WIREGUARD

python3 configurator
python3 certifier
