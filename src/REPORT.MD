
```ruby
Vagrant.configure("2") do |config|
  BOX = "ubuntu-22.04"   # jammy64
  CPU = 8
  RAM = 1500

  # приватная сеть (host-only)
  MANAGER_IP = "192.168.56.10"
  NODE01_IP  = "192.168.56.11"
  NODE02_IP  = "192.168.56.12"

  # manager
  config.vm.define "manager" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "manager"
    vm.vm.network "private_network", ip: MANAGER_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = RAM
    end
  end

  # node01 — сюда будем деплоить микросервисы; пробрасываем порты для доступа с хоста
  config.vm.define "node01" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "node01"
    vm.vm.network "private_network", ip: NODE01_IP
    # проброс портов для твоего compose (session:8081, gateway:8087)
    vm.vm.network "forwarded_port", guest: 8081, host: 8081, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.network "forwarded_port", guest: 8087, host: 8087, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = 5120
    end
  end

  # node02 — сюда позже назначим роли apache и postgres
  config.vm.define "node02" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "node02"
    vm.vm.network "private_network", ip: NODE02_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU
      vb.memory = RAM
    end
  end
end
```


Прокидывания ключа на node01 и node02 c manager

```bash
# на manager
ssh-keygen -t ed25519 -C "manager"
```

```bash
# на manager
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.11
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.12
```

```bash
ssh vagrant@192.168.56.11
ssh vagrant@192.168.56.12
```

```bash
# на ХОСТЕ
vagrant upload ../services/ /home/vagrant/services manager
```

```bash
# на manager
sudo apt update
sudo apt install -y ansible

mkdir -p ~/ansible
vim ~/ansible/inventory.yml
```

```yml
nodes:
  hosts:
    node01:
      ansible_host: 192.168.56.11
    node02:
      ansible_host: 192.168.56.12
  vars:
    ansible_user: vagrant
```

```bash
ansible -i ./ansible/inventory.yml all -m ping
```


```yml
---
- name: Prepare node01 and deploy microservices
  hosts: node01
  become: true
  vars:
    # На manager
    app_src_dir: /home/vagrant/services
    # Куда копируем на node01
    app_dest_dir: /home/vagrant/services
    compose_file: "{{ app_dest_dir }}/docker-compose.yml"
    docker_gpg_url: "https://download.docker.com/linux/ubuntu/gpg"
    docker_apt_repo: "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable"

  tasks:
    - name: Docker | Update repositories cache
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600 

    - name: Docker | Download Docker GPG key
      ansible.builtin.get_url:
        url: "{{ docker_gpg_url }}"
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"

    - name: Docker | Add Docker repository
      ansible.builtin.apt_repository:
        repo: "{{ docker_apt_repo }}"
        state: present # убедиться что репозиторий есть в системе
        filename: docker.list

    - name: Docker | Update repositories cache
      ansible.builtin.apt:
        update_cache: true

    - name: Docker | Install Docker packages
      ansible.builtin.apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-buildx-plugin
          - docker-compose-plugin
        state: present
        update_cache: true

    - name: Docker | enable and start service
      ansible.builtin.service:
        name: docker
        enabled: true
        state: started

    - name: Docker | add vagrant to docker group
      ansible.builtin.user:
        name: vagrant
        groups: docker
        append: true

    - name: node01 | ensure destination directory exists on node01
      ansible.builtin.file:
        path: "{{ app_dest_dir }}"
        state: directory
        owner: vagrant
        group: vagrant
        mode: "0755"

    - name: node01 | copy sources & compose from manager to node01
      ansible.builtin.copy:
        src: "{{ app_src_dir }}/docker-compose.yml"
        dest: "{{ app_dest_dir }}/docker-compose.yml"
        owner: vagrant
        group: vagrant
        mode: "0644"
        directory_mode: "0755"

    - name: Docker | pre-pull base images
      ansible.builtin.command:
        cmd: "docker compose -f {{ compose_file }} pull"
        chdir: "{{ app_dest_dir }}"
      register: compose_pull # сохраняем результат в переменную
      changed_when: "'Downloaded' in compose_pull.stdout or 'Pull complete' in compose_pull.stdout"

    - name: node01 | start containers
      ansible.builtin.command:
        cmd: "docker compose -f {{ compose_file }} up -d"
        chdir: "{{ app_dest_dir }}"
      register: compose_up

    - name: Wait | give containers time to warm up
      ansible.builtin.pause:
        seconds: 90

    - name: Info | show running containers
      ansible.builtin.command:
        argv:
          - docker
          - ps
          - --format
          - "{{'{{'}}.Names{{'}}'}}\t{{'{{'}}.Status{{'}}'}}\t{{'{{'}}.Ports{{'}}'}}"
      changed_when: false
      register: dps

    - name: Info | containers table
      ansible.builtin.debug:
        var: dps.stdout_lines
```

```yml
services:
  postgres:
    image: missille1/postgres:15.1-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: users_db
    networks:
      - booking_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  rabbitmq:
    image: rabbitmq:3-management-alpine
    networks:
      - booking_network

  session:
    image: missille1/services-session:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: users_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network
    ports:
      - "8081:8081"

  hotel:
    image: missille1/services-hotel:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: hotels_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  payment:
    image: missille1/services-payment:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: payments_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  loyalty:
    image: missille1/services-loyalty:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: balances_db
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  report:
    image: missille1/services-report:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: statistics_db
      RABBIT_MQ_HOST: rabbitmq
      RABBIT_MQ_PORT: 5672
      RABBIT_MQ_USER: guest
      RABBIT_MQ_PASSWORD: guest
      RABBIT_MQ_QUEUE_NAME: messagequeue
      RABBIT_MQ_EXCHANGE: messagequeue-exchange
    depends_on:
      - postgres
      - rabbitmq
    networks:
      - booking_network

  booking:
    image: missille1/services-booking:v1.1
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: reservations_db
      RABBIT_MQ_HOST: rabbitmq
      RABBIT_MQ_PORT: 5672
      RABBIT_MQ_USER: guest
      RABBIT_MQ_PASSWORD: guest
      RABBIT_MQ_QUEUE_NAME: messagequeue
      RABBIT_MQ_EXCHANGE: messagequeue-exchange
      HOTEL_SERVICE_HOST: hotel
      HOTEL_SERVICE_PORT: 8082
      PAYMENT_SERVICE_HOST: payment
      PAYMENT_SERVICE_PORT: 8084
      LOYALTY_SERVICE_HOST: loyalty
      LOYALTY_SERVICE_PORT: 8085
    depends_on:
      - postgres
      - rabbitmq
      - hotel
      - payment
      - loyalty
    networks:
      - booking_network

  gateway:
    image: missille1/services-gateway:v1.1
    networks:
      - booking_network
    depends_on:
      - postgres
      - rabbitmq
      - hotel
      - booking
      - payment
      - loyalty
      - report
      - session
    environment:
      SESSION_SERVICE_HOST: session
      SESSION_SERVICE_PORT: 8081
      HOTEL_SERVICE_HOST: hotel
      HOTEL_SERVICE_PORT: 8082
      BOOKING_SERVICE_HOST: booking
      BOOKING_SERVICE_PORT: 8083
      PAYMENT_SERVICE_HOST: payment
      PAYMENT_SERVICE_PORT: 8084
      LOYALTY_SERVICE_HOST: loyalty
      LOYALTY_SERVICE_PORT: 8085
      REPORT_SERVICE_HOST: report
      REPORT_SERVICE_PORT: 8086
    ports:
      - "8087:8087"
      
networks:
  booking_network:
    driver: bridge
```

```bash
# на manager
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/deploy_node01.yml
```

```bash
# на manager
cd ~/ansible
ansible-galaxy init roles/application
ansible-galaxy init roles/apache
ansible-galaxy init roles/postgres
```

чтобы ansible мог взаимодействовать в бд
```bash
# на manager
sudo ansible-galaxy collection install community.postgresql
```

```bash
printf '%s\n' '[defaults]' 'remote_tmp = /tmp' 'allow_world_readable_tmpfiles = False' > ansible.cfg
```

```bash
# node02
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'pgpass';"
```

```bash
# на хосте
psql "postgresql://postgres:pgpass@192.168.56.12:5432/school21" -c 'TABLE public.students;'
```

```
# на хосте apache
http://192.168.56.12/
```

```bash
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/site.yml
```

```ruby
Vagrant.configure("2") do |config|
  BOX = "ubuntu-22.04"
  CPU = 2
  RAM = 1300

  NET = "192.168.56"
  MANAGER_IP = "#{NET}.19"
  CONSUL_IP  = "#{NET}.20"
  API_IP     = "#{NET}.21"
  DB_IP      = "#{NET}.22"

  config.vm.define "manager" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "manager"
    vm.vm.network "private_network", ip: MANAGER_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU; vb.memory = RAM
    end
  end

  config.vm.define "consul_server" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "consul-server"
    vm.vm.network "private_network", ip: CONSUL_IP
    vm.vm.network "forwarded_port", guest: 8500, host: 8500, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU; vb.memory = RAM
    end
  end

  config.vm.define "api" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "api"
    vm.vm.network "private_network", ip: API_IP
    vm.vm.network "forwarded_port", guest: 8082, host: 8082, host_ip: "127.0.0.1", auto_correct: true
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU; vb.memory = RAM
    end
  end

  config.vm.define "db" do |vm|
    vm.vm.box = BOX
    vm.vm.hostname = "db"
    vm.vm.network "private_network", ip: DB_IP
    vm.vm.provider "virtualbox" do |vb|
      vb.cpus = CPU; vb.memory = RAM
    end
  end
end
```

прокидывание ключей 
```bash

ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

mkdir -p /tmp/ansible02

vagrant ssh manager -c "cat ~/.ssh/id_ed25519.pub" > /tmp/ansible02/manager.pub

vagrant upload /tmp/ansible02/manager.pub /home/vagrant/manager.pub db

vagrant ssh db -c "cat /home/vagrant/manager.pub >> ~vagrant/.ssh/authorized_keys \
  && rm /home/vagrant/manager.pub"

ssh vagrant@192.168.56.21 "echo OK && hostname -f"
```

закидываем сервис hotel и сборка
```bash
vagrant upload ../services/hotel-service /home/vagrant/hotel-service manager

sudo apt install -y wget curl gnupg2 software-properties-common

sudo add-apt-repository -y ppa:openjdk-r/ppa

sudo apt update

sudo apt install -y openjdk-8-jdk

java -version

sudo apt install -y maven

mvn -version

cd hotel-service/

mvn clean package -DskipTests

ls target/*.jar
```

создание ролей
```bash
sudo apt install ansible
mkdir -p ~/ansible02/roles
cd ~/ansible02
ansible-galaxy init roles/install_consul_server
ansible-galaxy init roles/install_consul_client
ansible-galaxy init roles/install_db
ansible-galaxy init roles/install_hotels_service
```

~/ansible02/inventory.yml
```
all:
  vars:
    ansible_user: vagrant
    consul_server_ip: 192.168.56.20
  hosts:
    manager:
      ansible_host: 192.168.56.19
      advertise_addr: 192.168.56.19
    consul_server:
      ansible_host: 192.168.56.20
      advertise_addr: 192.168.56.20
    api:
      ansible_host: 192.168.56.21
      advertise_addr: 192.168.56.21
    db:
      ansible_host: 192.168.56.22
      advertise_addr: 192.168.56.22
```
~/ansible02/site.yml
```
---
- name: Consul server
  hosts: consul_server
  become: true
  roles: [install_consul_server]

- name: Consul clients
  hosts: api,db
  become: true
  roles: [install_consul_client]

- name: Postgres on db
  hosts: db
  become: true
  roles: [install_db]

- name: Hotels service on api
  hosts: api
  become: true
  roles: [install_hotels_service]
```

```bash
ansible-galaxy collection install community.postgresql
```

Роль install_consul_server

~/ansible02/roles/install_consul_server/tasks/main.yml

```
---
- name: Install Consul from zip (minimal changes)
  hosts: all
  become: true

  vars:
    consul_version: "1.21.5"
    consul_arch: "amd64"
    consul_zip_url: "https://releases.hashicorp.com/consul/{{ consul_version }}/consul_{{ consul_version }}_linux_{{ consul_arch }}.zip"
    consul_zip_path: "/tmp/consul_{{ consul_version }}_linux_{{ consul_arch }}.zip"
    consul_unzip_dir: "/tmp/consul_{{ consul_version }}"

  tasks:
    - name: Install necessary packages for Consul
      apt:
        name:
          - curl
          - unzip
        state: present
        update_cache: true

    - name: Download Consul zip
      get_url:
        url: "{{ consul_zip_url }}"
        dest: "{{ consul_zip_path }}"
        mode: "0644"

    - name: Unzip Consul archive (get consul binary)
      unarchive:
        src: "{{ consul_zip_path }}"
        dest: "{{ consul_unzip_dir }}"
        remote_src: true
        creates: "{{ consul_unzip_dir }}/consul"

    - name: Copy Consul binary to /usr/local/bin
      copy:
        src: "{{ consul_unzip_dir }}/consul"
        dest: /usr/local/bin/consul
        mode: '0755'
        owner: root
        group: root
        remote_src: true

    - name: Create directories for Consul
      file:
        path: "{{ item }}"
        state: directory
      loop:
        - /opt/consul
        - /opt/consul/data
        - /etc/consul.d
        - /etc/consul.d/certs

    - name: Copy Consul server configuration file
      template:
        src: ~/ansible02/roles/install_consul_server/templates/consul_server.hcl
        dest: /etc/consul.d/consul.hcl
      notify: restart consul

    - name: Create Consul systemd service file
      copy:
        dest: /etc/systemd/system/consul.service
        content: |
          [Unit]
          Description=Consul Service
          After=network.target

          [Service]
          ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d
          Restart=on-failure

          [Install]
          WantedBy=multi-user.target
        mode: '0644'
      notify: restart consul

    - name: Ensure systemd reloads units and Consul is started
      service:
        name: consul
        state: started
        enabled: true
        daemon_reload: yes

  handlers:
    - name: daemon-reload
      systemd:
        daemon_reload: true

    - name: restart consul
      service:
        name: consul
        state: restarted
```

~/ansible02/roles/install_consul_server/templates/consul_server.hcl

```
server           = true
bootstrap_expect = 1
data_dir         = "/opt/consul"
bind_addr        = "0.0.0.0"
client_addr      = "0.0.0.0"
advertise_addr   = "{{ hostvars[inventory_hostname].advertise_addr }}"
ui_config { enabled = true }
connect  { enabled = true }
addresses { http = "0.0.0.0" }
retry_join = []
```

~/ansible02/roles/install_consul_client/tasks/main.yml

```
---
- name: Repos | prerequisites
  apt:
    name: [ca-certificates, curl, gnupg, apt-transport-https]
    state: present
    update_cache: true

- name: Hashicorp | keyring dir
  file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Hashicorp | GPG
  shell: |
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
  args: { creates: /etc/apt/keyrings/hashicorp.gpg }

- name: Hashicorp | repo
  apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com jammy main"
    filename: hashicorp
    state: present

- name: Consul | install
  apt:
    name: consul
    state: present
    update_cache: true

- name: Envoy | try install from Ubuntu repo
  apt:
    name: envoy
    state: present
    update_cache: true
  register: envoy_apt
  failed_when: false

- name: Envoy | setup getenvoy repo (fallback)
  block:
    - apt:
        name: [ca-certificates, curl, gnupg, apt-transport-https]
        state: present
        update_cache: true
    - shell: |
        curl -1sLf 'https://dl.getenvoy.io/public/repo/gpg.DA418C88.pub' | gpg --dearmor -o /usr/share/keyrings/getenvoy.gpg
      args: { creates: /usr/share/keyrings/getenvoy.gpg }
    - apt_repository:
        repo: "deb [signed-by=/usr/share/keyrings/getenvoy.gpg] https://dl.getenvoy.io/public/repo/deb/ubuntu jammy main"
        filename: getenvoy
        state: present
    - apt:
        name: envoy
        state: present
        update_cache: true
  when: envoy_apt is failed

- name: Consul | dirs
  file:
    path: "{{ item }}"
    state: directory
    owner: consul
    group: consul
    mode: "0755"
  loop:
    - /opt/consul
    - /etc/consul.d

- name: Consul | client config
  template:
    src: consul_client.hcl
    dest: /etc/consul.d/consul.hcl
    owner: consul
    group: consul
    mode: "0644"

- name: Systemd | consul-envoy template unit
  copy:
    dest: /etc/systemd/system/consul-envoy@.service
    mode: "0644"
    content: |
      [Unit]
      Description=Consul Envoy sidecar for %i
      After=consul.service
      Requires=consul.service

      [Service]
      ExecStart=/usr/bin/consul connect envoy -sidecar-for %i -admin-bind 0.0.0.0:19000
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target

- name: Consul | enable & start
  service:
    name: consul
    enabled: true
    state: started

- name: Consul | reload
  command: consul reload
  changed_when: true
```