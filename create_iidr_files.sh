#!/usr/bin/env bash
set -euo pipefail

# Creates directories and files for IIDR sample setup.
# Run this from the root of your cloned repo: ./create_iidr_files.sh

mkdir -p .github/workflows
mkdir -p ansible/playbooks
mkdir -p configs/datastores
mkdir -p configs/iidr/xml
mkdir -p init
mkdir -p scripts

cat > .github/workflows/deploy-iidr-sample.yml <<'EOF'
name: Deploy IIDR to staging
on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: [self-hosted, linux, internal]
    environment: staging
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Fetch IIDR installer from artifact store
        run: |
          mkdir -p installers
          curl -f -H "Authorization: Bearer ${{ secrets.ARTIFACT_TOKEN }}" \
            -o installers/iidr-installer.bin \
            "https://artifacts.internal.example.com/iidr/iidr-installer.bin"

      - name: Run Ansible playbook to install/configure IIDR
        uses: dawidd6/action-ansible-playbook@v3
        with:
          playbook: ansible/playbooks/deploy-iidr.yml
        env:
          IIDR_LICENSE: ${{ secrets.IIDR_LICENSE }}
          DB_USER: ${{ secrets.DB_USER }}
          DB_PASS: ${{ secrets.DB_PASS }}

      - name: Run smoke test (validate replication)
        run: |
          ./scripts/validate_replication.sh --env staging
EOF

cat > ansible/playbooks/deploy-iidr.yml <<'EOF'
---
- hosts: iidr_hosts
  become: yes
  vars:
    installer_src: "{{ playbook_dir }}/../../installers/iidr-installer.bin"
    install_dir: /opt/ibm/iidr
  tasks:
    - name: Upload IIDR installer
      copy:
        src: "{{ installer_src }}"
        dest: /tmp/iidr-installer.bin
        mode: '0755'

    - name: Run silent IIDR installer
      shell: "/tmp/iidr-installer.bin --silent --install-dir {{ install_dir }}"
      args:
        creates: "{{ install_dir }}/bin"

    - name: Render replication config from template
      template:
        src: "{{ playbook_dir }}/../../configs/templates/channel.j2"
        dest: /etc/iidr/channel.json
        mode: '0640'

    - name: Start IIDR service
      service:
        name: iidr
        state: started
EOF

cat > configs/datastores/source.yml <<'EOF'
# IIDR source datastore definition (template)
# Replace secrets with environment variables or refer to your secrets manager.
name: iidr-source
type: mysql             # supported types: mysql, postgres, db2, oracle, sqlserver, kafka, etc.
host: ${IIDR_SOURCE_HOST:-source-db}
port: ${IIDR_SOURCE_PORT:-3306}
database: sampledb
user: ${IIDR_SOURCE_USER:-source_user}
# Do NOT hardcode password — store in GitHub Secrets or Vault and reference it at runtime.
password_secret: IIDR_SOURCE_DB_PASSWORD   # name of secret that holds the password
jdbc_url: "jdbc:mysql://${IIDR_SOURCE_HOST:-source-db}:${IIDR_SOURCE_PORT:-3306}/${database}?useSSL=false&serverTimezone=UTC"
cdc_enabled: true        # enable change data capture options for source
cdc_settings:
  mode: log_based        # example: log_based or trigger_based
  capture_schema_changes: false
  snapshot_on_first_run: true
connection_test_query: "SELECT 1"
notes: |
  - This is a template used by deployment automation.
  - Use CI/CD to render host/user values from environment or secrets.
EOF

cat > configs/datastores/target.yml <<'EOF'
# IIDR target datastore definition (template)
name: iidr-target
type: mysql
host: ${IIDR_TARGET_HOST:-target-db}
port: ${IIDR_TARGET_PORT:-3306}
database: sampledb
user: ${IIDR_TARGET_USER:-target_user}
password_secret: IIDR_TARGET_DB_PASSWORD   # name of secret that holds the password
jdbc_url: "jdbc:mysql://${IIDR_TARGET_HOST:-target-db}:${IIDR_TARGET_PORT:-3306}/${database}?useSSL=false&serverTimezone=UTC"
cdc_enabled: false       # target usually doesn't capture changes; it's the apply side
apply_settings:
  apply_batch_size: 1000
  conflict_resolution: latest
connection_test_query: "SELECT 1"
notes: |
  - Keep credentials in secrets and never commit them.
  - Update apply_settings per your target performance needs.
EOF

cat > configs/iidr/xml/customers_source_table.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Source table definition (example) -->
<tableDefinition>
  <datastoreRef name="iidr-source"/>
  <schemaName>sampledb</schemaName>
  <tableName>customers</tableName>
  <primaryKey>
    <column name="id" type="INT" nullable="false" autoIncrement="true"/>
  </primaryKey>
  <columns>
    <column name="id" type="INT" nullable="false"/>
    <column name="name" type="VARCHAR" length="100" nullable="false"/>
    <column name="email" type="VARCHAR" length="150" nullable="true"/>
    <column name="created_at" type="TIMESTAMP" nullable="true" default="CURRENT_TIMESTAMP"/>
  </columns>
  <notes>
    <![CDATA[
      - This file describes the source table schema for change capture.
      - Do not put credentials here; datastoreRef should match a secured datastore entry.
      - Adjust types/lengths to exactly match your source DB.
    ]]>
  </notes>
</tableDefinition>
EOF

cat > configs/iidr/xml/customers_target_table.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Target table definition (example) -->
<tableDefinition>
  <datastoreRef name="iidr-target"/>
  <schemaName>sampledb</schemaName>
  <tableName>customers</tableName>
  <primaryKey>
    <column name="id" type="INT" nullable="false"/>
  </primaryKey>
  <columns>
    <column name="id" type="INT" nullable="false"/>
    <column name="name" type="VARCHAR" length="100" nullable="false"/>
    <column name="email" type="VARCHAR" length="150" nullable="true"/>
    <column name="created_at" type="TIMESTAMP" nullable="true"/>
  </columns>
  <notes>
    <![CDATA[
      - This file describes the target table schema for apply/replication.
      - Ensure schema and types are compatible (or provide explicit mappings).
      - If target uses different types/names, update columns and mapping in the channel file.
    ]]>
  </notes>
</tableDefinition>
EOF

cat > configs/iidr/xml/customers_channel.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Simple replication channel mapping source -> target for customers table -->
<replicationChannel>
  <channelName>customers_channel</channelName>
  <sourceDatastore ref="iidr-source"/>
  <targetDatastore ref="iidr-target"/>
  <tables>
    <tableMap>
      <source>
        <schema>sampledb</schema>
        <table>customers</table>
      </source>
      <target>
        <schema>sampledb</schema>
        <table>customers</table>
      </target>
      <columnMappings>
        <map>
          <sourceColumn>id</sourceColumn>
          <targetColumn>id</targetColumn>
        </map>
        <map>
          <sourceColumn>name</sourceColumn>
          <targetColumn>name</targetColumn>
        </map>
        <map>
          <sourceColumn>email</sourceColumn>
          <targetColumn>email</targetColumn>
        </map>
        <map>
          <sourceColumn>created_at</sourceColumn>
          <targetColumn>created_at</targetColumn>
        </map>
      </columnMappings>
      <options>
        <capture>true</capture>
        <apply>true</apply>
        <initialSnapshot>true</initialSnapshot>
        <conflictResolution>source-wins</conflictResolution>
      </options>
    </tableMap>
  </tables>

  <channelSettings>
    <name>customers_channel</name>
    <description>Replicate customers table from source to target (example)</description>
    <logging level="info"/>
    <performance>
      <applyBatchSize>500</applyBatchSize>
      <latencyToleranceSeconds>5</latencyToleranceSeconds>
    </performance>
  </channelSettings>
</replicationChannel>
EOF

cat > configs/iidr/xml/customers_subscription.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<subscription>
  <subscriptionName>customers_subscription</subscriptionName>

  <!-- Reference the replication channel you created -->
  <channelRef>
    <channelName>customers_channel</channelName>
  </channelRef>

  <!-- Logical datastore references (must match your datastore config names) -->
  <sourceDatastoreRef>iidr-source</sourceDatastoreRef>
  <targetDatastoreRef>iidr-target</targetDatastoreRef>

  <!-- Which tables/columns to include in this subscription -->
  <tables>
    <table>
      <schemaName>sampledb</schemaName>
      <tableName>customers</tableName>

      <columns>
        <column>id</column>
        <column>name</column>
        <column>email</column>
        <column>created_at</column>
      </columns>

    </table>
  </tables>

  <!-- Subscription behavior options -->
  <options>
    <!-- Run an initial snapshot/copy before starting CDC -->
    <initialSnapshot>true</initialSnapshot>

    <!-- How the apply should process transactions: transaction | row -->
    <applyMode>transaction</applyMode>

    <!-- Conflict handling: source-wins | target-wins | custom -->
    <conflictResolution>source-wins</conflictResolution>

    <!-- Whether the subscription will be enabled immediately after import -->
    <enabled>true</enabled>
  </options>

  <notes>
    <![CDATA[
      - Use your IIDR management/import tool or CLI to import this subscription XML.
      - Make sure datastore names (iidr-source, iidr-target) match your configured datastores.
      - If your IIDR version expects different XML tags or JSON, adapt this template accordingly.
    ]]>
  </notes>
</subscription>
EOF

cat > configs/iidr/xml/customers_subscription_apply_settings.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<subscriptionApplySettings>
  <subscriptionName>customers_subscription</subscriptionName>

  <applySettings>
    <!-- Number of rows per apply batch -->
    <applyBatchSize>500</applyBatchSize>

    <!-- Maximum time (seconds) to wait before flushing partial batch -->
    <applyBatchTimeoutSeconds>5</applyBatchTimeoutSeconds>

    <!-- Whether to apply changes within transaction boundaries -->
    <transactionalApply>true</transactionalApply>

    <!-- Retry policy for transient apply errors -->
    <retries>
      <maxAttempts>5</maxAttempts>
      <backoffSeconds>10</backoffSeconds>
    </retries>

    <!-- Behavior on persistent conflict or error: stop | skip | route-to-dlq -->
    <onError>route-to-dlq</onError>

    <!-- Dead-letter (error) table config on target (optional) -->
    <deadLetter>
      <enabled>true</enabled>
      <tableName>iidr_dead_letter</tableName>
      <schemaName>sampledb</schemaName>
    </deadLetter>

    <!-- Logging / monitoring -->
    <metricsEnabled>true</metricsEnabled>
    <logLevel>info</logLevel>
  </applySettings>

  <notes>
    <![CDATA[
      - Tune applyBatchSize and transactionalApply according to target DB capabilities.
      - If using route-to-dlq, ensure the deadLetter table exists or is created during import.
      - Some IIDR versions expose these settings through a different tagset or in a separate management UI.
    ]]>
  </notes>
</subscriptionApplySettings>
EOF

cat > docker-compose.yml <<'EOF'
version: "3.8"
services:
  source-db:
    image: mysql:8.0
    container_name: source-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: sampledb
      MYSQL_USER: source_user
      MYSQL_PASSWORD: source_pass
    ports:
      - "3307:3306"   # host port 3307 -> container 3306
    volumes:
      - ./init/source-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro

  target-db:
    image: mysql:8.0
    container_name: target-db
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: sampledb
      MYSQL_USER: target_user
      MYSQL_PASSWORD: target_pass
    ports:
      - "3308:3306"   # host port 3308 -> container 3306
    volumes:
      - ./init/target-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro

# Notes:
# - This is for local testing only. Do not use these example passwords in production.
# - Adjust ports if they conflict with local MySQL.
EOF

cat > init/source-init.sql <<'EOF'
-- Create schema and seed sample data for source DB
CREATE DATABASE IF NOT EXISTS sampledb;
USE sampledb;

CREATE TABLE IF NOT EXISTS customers (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(150),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO customers (name, email) VALUES ('Alice Source', 'alice.source@example.com');
EOF

cat > init/target-init.sql <<'EOF'
-- Create schema for target DB (matching schema to receive replication)
CREATE DATABASE IF NOT EXISTS sampledb;
USE sampledb;

CREATE TABLE IF NOT EXISTS customers (
  id INT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(150),
  created_at TIMESTAMP
);

-- No seed insert here — target will receive rows from source via replication
EOF

cat > scripts/check_datastores.sh <<'EOF'
#!/usr/bin/env bash
# Quick connectivity check for local docker test databases
set -euo pipefail

echo "Checking source DB (host=localhost port=3307)..."
mysql --protocol=TCP -h127.0.0.1 -P3307 -usource_user -psource_pass -e "SELECT COUNT(*) FROM sampledb.customers;" || {
  echo "Failed to connect to source DB"; exit 1
}

echo "Checking target DB (host=localhost port=3308)..."
mysql --protocol=TCP -h127.0.0.1 -P3308 -utarget_user -ptarget_pass -e "SHOW TABLES IN sampledb;" || {
  echo "Failed to connect to target DB"; exit 1
}

echo "Datastore checks OK"
EOF

cat > scripts/validate_replication.sh <<'EOF'
#!/usr/bin/env bash
set -e
# usage: ./validate_replication.sh --env staging

if [ $# -lt 1 ]; then
  echo "usage: $0 --env <env>"
  exit 1
fi

ENV="$2"
echo "Running smoke test for ${ENV}..."

# Example smoke test steps (replace with real DB/IIDR commands)
# 1) Insert row into source
mysql --protocol=TCP -h127.0.0.1 -P3307 -usource_user -psource_pass -e "INSERT INTO sampledb.customers (name,email) VALUES ('Smoke Test','smoke@example.com');"

# 2) Wait a short moment for replication to apply
sleep 5

# 3) Check target for the inserted row
COUNT=$(mysql --protocol=TCP -h127.0.0.1 -P3308 -utarget_user -ptarget_pass -sse "SELECT COUNT(*) FROM sampledb.customers WHERE email='smoke@example.com';")
if [ "$COUNT" -ge 1 ]; then
  echo "Smoke test: replicated rows found on target."
  exit 0
else
  echo "Smoke test: no replicated rows on target."
  exit 2
fi
EOF

cat > README.md <<'EOF'
# IIDR Sample Setup

This repository contains sample files to help test IIDR replication of a sample `customers` table from a source MySQL to a target MySQL.

Important notes:
- Do NOT commit real installers or license keys. The workflow references an internal artifact store; provide the installer and license via your secure store and secrets.
- Replace example passwords in `docker-compose.yml` with secure methods for production; these are for local testing only.

Quick start (local testing):
1. Start the test databases:
