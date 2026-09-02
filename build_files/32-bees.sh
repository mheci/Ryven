#!/bin/bash
# bees from Fedora. Instantiate beesd@UUID on the btrfs UUID of /var/home.

set -ouex pipefail

dnf5 -y install bees

mkdir -p /usr/lib/systemd/system-generators /usr/libexec /etc/bees

cat >/usr/libexec/ryven-bees-configure <<'EOF'
#!/bin/bash
set -euo pipefail
UUID=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID /)
[[ -n ${UUID} ]] || exit 0
FSTYPE=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE /)
[[ ${FSTYPE} == btrfs ]] || exit 0
mkdir -p /etc/bees
cat >/etc/bees/${UUID}.conf <<CONF
UUID=${UUID}
CONF
EOF
chmod +x /usr/libexec/ryven-bees-configure

cat >/usr/lib/systemd/system-generators/ryven-bees-generator <<'EOF'
#!/bin/bash
set -euo pipefail
normal=${1:-/run/systemd/generator}
UUID=$(findmnt -n -o UUID /var/home 2>/dev/null || findmnt -n -o UUID / || true)
[[ -n ${UUID} ]] || exit 0
FSTYPE=$(findmnt -n -o FSTYPE /var/home 2>/dev/null || findmnt -n -o FSTYPE / || true)
[[ ${FSTYPE} == btrfs ]] || exit 0
mkdir -p "${normal}/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/beesd@.service "${normal}/beesd@${UUID}.service"
ln -sf "../beesd@${UUID}.service" "${normal}/multi-user.target.wants/beesd@${UUID}.service"
EOF
chmod +x /usr/lib/systemd/system-generators/ryven-bees-generator

mkdir -p /usr/lib/systemd/system
cat >/usr/lib/systemd/system/ryven-bees-configure.service <<'EOF'
[Unit]
Description=Write beesd UUID config for the host btrfs
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/ryven-bees-configure
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable ryven-bees-configure.service
