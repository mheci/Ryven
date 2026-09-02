#!/bin/bash
# bees: background BEDUP on Steam/Proton Wine prefixes (compatdata).

set -ouex pipefail

dnf5 -y install --enablerepo=terra bees

mkdir -p /usr/lib/systemd/system
cat >/usr/lib/systemd/system/ryven-bees.service <<'EOF'
[Unit]
Description=bees dedup for Steam Proton compatdata
Documentation=man:bees(8)
After=local-fs.target
ConditionDirectoryNotEmpty=/var/home

[Service]
Type=simple
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/libexec/ryven-bees
Restart=on-failure
RestartSec=1h

[Install]
WantedBy=multi-user.target
EOF

cat >/usr/lib/systemd/system/ryven-bees.timer <<'EOF'
[Unit]
Description=Weekly bees on Wine prefixes

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=6h

[Install]
WantedBy=timers.target
EOF

cat >/usr/libexec/ryven-bees <<'EOF'
#!/bin/bash
set -euo pipefail
shopt -s nullglob
for home in /var/home/* /home/*; do
  compat="${home}/.local/share/Steam/steamapps/compatdata"
  [[ -d ${compat} ]] || continue
  if command -v beesd >/dev/null; then
    ionice -c3 beesd --scan "${compat}"
  else
    ionice -c3 bees "${compat}"
  fi
done
EOF
chmod +x /usr/libexec/ryven-bees
systemctl enable ryven-bees.timer
