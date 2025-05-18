Backup- und Restore-Dokumentation (Best Practice)

Diese Dokumentation fasst den infrastruktur-weiten Backup-Prozess zusammen, den wir per Ansible auf Ihrem IONOS-Server implementiert haben. Ziel ist ein herausragend sicheres, versioniertes und wiederherstellbares Backup-Konzept für:
	•	Datenbanken (MySQL)
	•	Block-Storage-Snapshots (IONOS-API)
	•	File-Level-Backups (Restic)
	•	Infrastructure as Code (Ansible-Playbooks)

⸻

Inhaltsverzeichnis
	1.	Ziele & Anforderungen
	2.	Übersicht der Komponenten
	3.	Voraussetzungen
	4.	Implementierung mit Ansible
	1.	Inventory & Vault
	2.	Basis-Playbook (site.yml)
	3.	Phase 1: Apache & UFW
	4.	Phase 2: MySQL-Backups
	5.	Phase 3: IONOS-Snapshots
	6.	Phase 4: Restic-Backups
	5.	Test & Validierung
	6.	Restore-Prozeduren
	7.	Wartung & Monitoring
	8.	Security & Best Practices

⸻

Ziele & Anforderungen
	•	RPO: Bis zu 24 Stunden für DB-Dumps, Volumen-Snapshots und File-Backups
	•	RTO: Wiederherstellung in maximal 2 Stunden (gemäß geübtem Restore)
	•	Versionierung: Alle Server-Configs in Git (Ansible-Playbooks), DB-Dumps, Snapshots & Restic-Snapshots nach Zeitpunkten abrufbar
	•	Automatisierung: Vollständige Orchestrierung via Ansible → Repeatable, Idempotent, Review­bar
	•	Sicherheit:
	•	Klartext-Passwörter und Tokens nur in Ansible Vault
	•	SSH-Deploy-Keys für Git­Hub
	•	File-Backups clientseitig verschlüsselt (Restic-Passphrase)
	•	Bucket- und Snapshot-Zugriffe via fein granulierte API-Tokens

⸻

Übersicht der Komponenten

Layer
Tool / Mechanismus
Zeitplan
Infra as Code
Ansible-Playbooks (GitHub-Repo)
on-demand
DB-Backups
mysqldump → /var/backups/mysql/*.sql.gz
täglich 03:00
Volume-Snapshots
IONOS API → /usr/local/bin/ionos-snapshot.sh via Cron
täglich 01:00
File-Level-Backups
Restic → S3 (Ionos)
täglich 02:30
Retention
MySQL: 14 Tage; Restic: 14 daily, 4 weekly; Snapshots: unbegrenzt im Portal
–

⸻

Voraussetzungen
	1.	IONOS Cloud Server mit root- oder sudo-Zugang
	2.	Ansible & Git auf dem Server installiert
	3.	SSH-Deploy-Key in GitHub-Repo als Deploy Key (write-zugriff)
	4.	Ansible Vault für alle Secrets (Cloudflare, IONOS)
	5.	Restic und curl vorhanden (wird per Playbook installiert)

⸻

Implementierung mit Ansible

Inventory & Vault

# inventory.yml
all:
  hosts:
    ubuntu:
      ansible_connection: local
      become: true

# group_vars/all/vault.yml (verschlüsselt via ansible-vault)
cf_api_token:    "<CLOUDFLARE_TOKEN>"
db_root_password:"<MYSQL_ROOT_PASS>"
ionos_token:     "<IONOS_API_TOKEN>"
server_id:       "c111338f-85cc-4022-8752-f1a7e9aec9f6"
volume_id:       "a4861336-db80-41e6-8207-193a80610b73"
restic_s3_endpoint: "s3.eu-central-3.ionoscloud.com"
restic_bucket:       "my-backups"
restic_access_key:   "<S3_ACCESS_KEY>"
restic_secret_key:   "<S3_SECRET_KEY>"
restic_repo:         "s3:{{ restic_s3_endpoint }}/{{ restic_bucket }}"
restic_password:     "<RESTIC_REPO_PASSPHRASE>"

Basis-Playbook (site.yml)

- hosts: ubuntu
  become: true
  tasks:
    - name: Ensure Apache and UFW are installed
      apt:
        name: [apache2, ufw]
        state: present
        update_cache: yes

Phase 1: Apache & UFW

    - name: Ensure UFW allows SSH
      ufw:
        rule: allow
        port: '22'
    - name: Ensure UFW allows HTTP
      ufw:
        rule: allow
        port: '80'
    - name: Ensure UFW allows HTTPS
      ufw:
        rule: allow
        port: '443'
    - name: Enable UFW
      ufw:
        state: enabled

Phase 2: MySQL-Backups

    - name: Ensure MySQL backup directory exists
      file:
        path: /var/backups/mysql
        state: directory
        mode: '0700'
    - name: Schedule daily MySQL dump at 03:00
      cron:
        name: "daily mysql backup"
        minute: "0"
        hour: "3"
        job: >
          mysqldump --single-transaction --routines --events --all-databases |
          gzip > /var/backups/mysql/backup-$(date +\%F).sql.gz
        user: root
    - name: Remove MySQL backups older than 14 days
      cron:
        name: "cleanup old mysql backups"
        minute: "0"
        hour: "4"
        job: "find /var/backups/mysql -type f -mtime +14 -name '*.gz' -delete"
        user: root

Phase 3: IONOS-Snapshots

    - name: Ensure snapshot script directory exists
      file:
        path: /usr/local/bin
        state: directory
        mode: '0755'
    - name: Deploy IONOS snapshot script
      copy:
        dest: /usr/local/bin/ionos-snapshot.sh
        content: |
          #!/usr/bin/env bash
          export IONOS_TOKEN="{{ ionos_token }}"
          SERVER_ID="{{ server_id }}"
          VOLUME_ID="{{ volume_id }}"
          curl -s -X POST \
            "https://api.ionos.com/cloudapi/v5/servers/${SERVER_ID}/volumes/${VOLUME_ID}/create-snapshot" \
            -H "Authorization: Bearer ${IONOS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"name":"snapshot-'"$(date +%F)"'"}'
        mode: '0755'
    - name: Schedule daily IONOS snapshot at 01:00
      cron:
        name: "daily ionos snapshot"
        minute: "0"
        hour: "1"
        job: "/usr/local/bin/ionos-snapshot.sh"
        user: root

Phase 4: Restic-Backups

    - name: Download Restic
      get_url:
        url: https://github.com/restic/restic/releases/download/v0.18.0/restic_0.18.0_linux_amd64.bz2
        dest: /tmp/restic.bz2
    - name: Install Restic if new
      shell: |
        bunzip2 /tmp/restic.bz2 && mv /tmp/restic /usr/local/bin/restic && chmod +x /usr/local/bin/restic
      args:
        creates: /usr/local/bin/restic
    - name: Write Restic env file
      copy:
        dest: /etc/restic.env
        content: |
          export RESTIC_REPOSITORY={{ restic_repo }}
          export RESTIC_PASSWORD={{ restic_password }}
          export AWS_ACCESS_KEY_ID={{ restic_access_key }}
          export AWS_SECRET_ACCESS_KEY={{ restic_secret_key }}
        mode: '0600'
    - name: Deploy Restic backup script
      copy:
        dest: /usr/local/bin/restic-backup.sh
        content: |
          #!/usr/bin/env bash
          source /etc/restic.env
          restic backup /etc /opt/infra-playbooks /var/www
          restic forget --keep-daily 14 --keep-weekly 4 --prune
        mode: '0755'
    - name: Schedule daily Restic backup at 02:30
      cron:
        name: "daily restic backup"
        minute: "30"
        hour: "2"
        job: "/usr/local/bin/restic-backup.sh"
        user: root

⸻

Test & Validierung
	1.	Ansible-Run:

ansible-playbook -i inventory.yml site.yml --ask-vault-pass

→ alle Tasks: ok/changed, keine failed.

	2.	Cron-Jobs prüfen:
 sudo crontab -l -u root

 	3.	Manueller Backup-Test:
  sudo /usr/local/bin/ionos-snapshot.sh
  sudo /usr/local/bin/restic-backup.sh
  restic snapshots
  ls /var/backups/mysql

  4.	Restore-Test:
  sudo restic restore latest --target /tmp/restore-test
  gunzip -c /var/backups/mysql/backup-2025-05-17.sql.gz | mysql -u root -p

Restore-Prozeduren

Komponente
Befehl
MySQL
gunzip -c backup-YYYY-MM-DD.sql.gz | mysql -u root -p
Restic
restic restore latest --target /path/to/restore
Volume-Snapshot
IONOS-Portal: Volume aus Snapshot wiederherstellen oder via API restore-snapshot call


⸻

Wartung & Monitoring
	•	Cron-Mails aktivieren (MAILTO= in /etc/cron.d/*.cron)
	•	Logwatch oder Prometheus-Alert für Fehlermeldungen
	•	Quarterly Restore-Übungen in isolierter Test-VM durchlaufen
	•	Token-Rotation (90 Tage) und Passwort-Rotation (Vault, Restic)

⸻

Security & Best Practices
	•	Trennung von Code & Secrets: Ansible-Playbooks in Git, Secrets in Vault
	•	Least Privilege: Root-Cron-Jobs, API-Tokens mit minimalen Rechten
	•	Verschlüsselung: Restic Repository verschlüsselt, SSL/TLS für HTTP
	•	Dokumentation: Diese Datei im Repo unter docs/backup.md ablegen
	•	Compliance: Aufbewahrungs- und Datenschutzvorgaben prüfen und anpassen

⸻
