## Part 1. Удаленное конфигурирование узла через Ansible

### Создал с помощью Vagrant три машины: manager, node01, node02. Не устанавливал с помощью shell-скриптов docker при создании машин на Vagrant! Прокинул порты node01 на локальную машину для доступа к пока еще не развернутому микросервисному приложению.

<details>
<summary>Vagrant конфиг</summary>

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
</details>

### Подготовил manager как рабочую станцию для удаленного конфигурирования.

#### Зашел на manager. На manager проверил подключение к node01 через ssh по приватной сети. Сгенерировать ssh-ключ для подключения к node01 из manager (без passphrase).

```bash
vagrant ssh manager
ssh vagrant@192.168.56.11
```

##### Прокидывания ключа на node01 и node02 c manager

```bash
# на manager
ssh-keygen -t ed25519 -C "manager"
```

```bash
# на manager
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.11
ssh-copy-id -i ~/.ssh/ vagrant@192.168.56.12
```

<img src="img/addkeystonodes.png">

```bash
# на manager
ssh vagrant@192.168.56.11
ssh vagrant@192.168.56.12
```

<img src="img/sshwork1.png">

<details>
<summary>PS: Если не работает вход по паролю</summary>

```bash
mkdir -p /tmp/ansible01
vagrant ssh manager
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
CTRL+D
vagrant ssh manager -c "cat ~/.ssh/id_ed25519.pub" > /tmp/ansible01/manager.pub
vagrant upload /tmp/ansible02/manager.pub /home/vagrant/manager.pub manager
vagrant ssh manager -c "cat /home/vagrant/manager.pub >> ~vagrant/.ssh/authorized_keys \\n  && rm /home/vagrant/manager.pub"
```

</details>

#### Скопировал на manager docker-compose файл и исходный код микросервисов. (Использовал проект из папки src и docker-compose файл из D07.)

```bash
# на ХОСТЕ
vagrant upload ../services/ /home/vagrant/services manager
```

<details>
<summary>docker-compose</summary>

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

</details>


#### Установил Ansible на менеджер и создал папку ansible, в которой создал inventory-файл.

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

#### Использовал модуль ping для проверки подключения через Ansible.

```bash
ansible -i ./ansible/inventory.yml all -m ping
```

<img src="img/ansibleping.png">

### Написал первый плейбук для Ansible, который выполняет apt update, устанавливает docker, docker-compose, копирует compose-файл из manager'а и разворачивает микросервисное приложение.

<details>
<summary>playbook</summary>

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
      apt:
        update_cache: true
        cache_valid_time: 3600 

    - name: Docker | Download Docker GPG key
      get_url:
        url: "{{ docker_gpg_url }}"
        dest: /etc/apt/keyrings/docker.asc
        mode: "0644"

    - name: Docker | Add Docker repository
      apt_repository:
        repo: "{{ docker_apt_repo }}"
        state: present # убедиться что репозиторий есть в системе
        filename: docker.list

    - name: Docker | Update repositories cache
      apt:
        update_cache: true

    - name: Docker | Install Docker packages
      apt:
        name:
          - docker-ce
          - docker-ce-cli
          - containerd.io
          - docker-buildx-plugin
          - docker-compose-plugin
        state: present
        update_cache: true

    - name: Docker | enable and start service
      service:
        name: docker
        enabled: true
        state: started

    - name: Docker | add vagrant to docker group
      user:
        name: vagrant
        groups: docker
        append: true

    - name: node01 | ensure destination directory exists on node01
      file:
        path: "{{ app_dest_dir }}"
        state: directory
        owner: vagrant
        group: vagrant
        mode: "0755"

    - name: node01 | copy sources & compose from manager to node01
      copy:
        src: "{{ app_src_dir }}/docker-compose.yml"
        dest: "{{ app_dest_dir }}/docker-compose.yml"
        owner: vagrant
        group: vagrant
        mode: "0644"
        directory_mode: "0755"

    - name: Docker | pre-pull base images
      command:
        cmd: "docker compose -f {{ compose_file }} pull"
        chdir: "{{ app_dest_dir }}"
      register: compose_pull # сохраняем результат в переменную
      changed_when: "'Downloaded' in compose_pull.stdout or 'Pull complete' in compose_pull.stdout"

    - name: node01 | start containers
      command:
        cmd: "docker compose -f {{ compose_file }} up -d"
        chdir: "{{ app_dest_dir }}"
      register: compose_up

    - name: Wait | give containers time to warm up
      pause:
        seconds: 90

    - name: Info | show running containers
      command:
        argv:
          - docker
          - ps
          - --format
          - "{{'{{'}}.Names{{'}}'}}\t{{'{{'}}.Status{{'}}'}}\t{{'{{'}}.Ports{{'}}'}}"
      changed_when: false
      register: dps

    - name: Info | containers table
      debug:
        var: dps.stdout_lines
```
<details>

Запуск playbook

```bash
# на manager
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/deploy_node01.yml
```

<details>
<summary>Скрин работы ansible</summary>

<img src="img/ansiblework.png">

<details>

#### Прогнал заготовленные тесты через postman и удостовериться, что все они проходят успешно.

<details>
<summary>Скрин тестов Postman</summary>

<img src="img/postamn1.4.png">

<details>

#### Сформировал три роли application, apache и postgres. Роль application выполняет развертывание микросервисного приложения при помощи docker-compose node01. Apache устанавливает и запускает стандартный apache сервер node02. Postgres устанавливает и запускает postgres, создает базу данных с произвольной таблицей и добавляет в нее три произвольные записи node02. 

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

<details>
<summary>PS: Для записи в db от пользователя vagrant может понадобиться</summary>

```bash
printf '%s\n' '[defaults]' 'remote_tmp = /tmp' 'allow_world_readable_tmpfiles = False' > ansible.cfg
```

```bash
# node02
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'pgpass';"
```

<details>

Написал site.yml для ansible, чтобы указать на каких машинах, что разворачиваем. 

```yml
---
# node01: микросервисы 
- name: Application stack on node01
  hosts: node01
  become: true
  roles:
    - role: application

# node02: apache + postgres
- name: Apache and Postgres on node02
  hosts: node02
  become: true
  roles:
    - role: apache
    - role: postgres
```


<details>
<summary>tasks для ролей</summary>

```yml
---
# tasks file for roles/apache
- name: Apt | Update cache
  apt:
    update_cache: true
    cache_valid_time: 3600

- name: Apt | Install apache2
  apt:
    name: apache2
    state: present

- name: Apache | Enable and start
  service:
    name: apache2
    enabled: true
    state: started
```

```yml
---
# tasks file for roles/application

- name: Docker | Ensure keyrings dir exists
  file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"

- name: Docker | Update repositories cache
  apt:
    update_cache: true
    cache_valid_time: 3600

- name: Docker | Download Docker GPG key (armored)
  get_url:
    url: "{{ docker_gpg_url }}"
    dest: /etc/apt/keyrings/docker.asc
    mode: "0644"

- name: Docker | Convert armored key to .gpg (dearmor)
  command:
    cmd: gpg --dearmor -o /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/docker.asc
  args:
    creates: /etc/apt/keyrings/docker.gpg

- name: Docker | Add Docker repository
  apt_repository:
    repo: "{{ docker_apt_repo }}"
    state: present
    filename: docker.list

- name: Docker | Update repositories cache (after adding repo)
  apt:
    update_cache: true

- name: Docker | Install Docker packages
  apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
    state: present
    update_cache: true

- name: Docker | Enable and start service
  service:
    name: docker
    enabled: true
    state: started

- name: Docker | Add vagrant to docker group
  user:
    name: vagrant
    groups: docker
    append: true

- name: node01 | Ensure destination directory exists
  file:
    path: "{{ app_dest_dir }}"
    state: directory
    owner: vagrant
    group: vagrant
    mode: "0755"

- name: node01 | Copy compose file
  copy:
    src: "{{ compose_file }}"
    dest: "{{ compose_file }}"
    owner: vagrant
    group: vagrant
    mode: "0644"
    directory_mode: "0755"

- name: Docker | Pre-pull base images
  command:
    cmd: "docker compose -f {{ compose_file }} pull"
    chdir: "{{ app_dest_dir }}"
  register: compose_pull
  changed_when: >
    'Downloaded' in compose_pull.stdout
    or 'Pull complete' in compose_pull.stdout

- name: node01 | Start containers
  command:
    cmd: "docker compose -f {{ compose_file }} up -d"
    chdir: "{{ app_dest_dir }}"
  register: compose_up

- name: Wait | Give containers time to warm up
  pause:
    seconds: 30

- name: Info | Show running containers
  command:
    argv:
      - docker
      - ps
      - --format
      - "{{'{{'}}.Names{{'}}'}}\t{{'{{'}}.Status{{'}}'}}\t{{'{{'}}.Ports{{'}}'}}"
  changed_when: false
  register: dp

- name: Info | Containers table
  debug:
    var: dp.stdout_lines
```

```yml
---
- name: Apt | Update cache
  apt:
    update_cache: true
    cache_valid_time: 3600

- name: Apt | Install ACL (for become_user file perms)
  apt:
    name: acl
    state: present
    update_cache: true
  become: true

- name: Apt | Install Postgres and deps
  apt:
    name:
      - "postgresql-{{ postgresql_version }}"
      - postgresql-contrib
      - python3-psycopg2
    state: present

- name: Postgres | Ensure service started
  service:
    name: postgresql
    enabled: true
    state: started

- name: Postgres | Listen on all addresses
  lineinfile:
    path: "/etc/postgresql/{{ postgresql_version }}/main/postgresql.conf"
    regexp: '^#?listen_addresses\s*='
    line: "listen_addresses = '*'"
  notify: Restart Postgres
  become: true

- name: Postgres | Allow LAN in pg_hba.conf
  blockinfile:
    path: "/etc/postgresql/{{ postgresql_version }}/main/pg_hba.conf"
    marker: "# {mark} ANSIBLE MANAGED BLOCK FOR LAN ACCESS"
    block: |
      host    all    all    {{ pg_listen_cidr }}    md5
  notify: Restart Postgres

- name: DB | Ensure database exists (owner = postgres)
  community.postgresql.postgresql_db:
    name: "{{ pg_db }}"
    owner: postgres
    login_unix_socket: /var/run/postgresql
  become: true
  become_user: postgres

- name: DB | Create table if not exists
  community.postgresql.postgresql_query:
    db: "{{ pg_db }}"
    query: |
      CREATE TABLE IF NOT EXISTS public.students(
        id   SERIAL PRIMARY KEY,
        name TEXT UNIQUE
      );
    login_unix_socket: /var/run/postgresql
  become: true
  become_user: postgres

- name: DB | Insert three rows
  community.postgresql.postgresql_query:
    db: "{{ pg_db }}"
    query: |
      INSERT INTO public.students(name) VALUES
        ('Ramonagr'),
        ('Sandiani'),
        ('Nutmegha')
      ON CONFLICT (name) DO NOTHING;
    login_unix_socket: /var/run/postgresql
  become: true
  become_user: postgres

- name: Postgres | Final restart
  service:
    name: postgresql
    state: restarted
```

<details>

Запускаем ansible

```bash
ansible-playbook -i ~/ansible/inventory.yml ~/ansible/site.yml
```

Проверяем postman-тестами работоспособность микросервисного приложения. Для Apache веб-страница открывается в браузере хоста. Для PostgreSQL,подключился с локальной машины и отобразил содержимое ранее созданной таблицы с данными. 

<details>
<summary>tasks для ролей</summary>

<img src="img/1endpostman.png">

```
# на хосте apache
http://192.168.56.12/
```

<img src="img/01apache.png">

```bash
# на хосте
psql "postgresql://postgres:pgpass@192.168.56.12:5432/school21" -c 'TABLE public.students;'
```

<img src="img/01psql.png">

Распределение файлов по папкам на manager

<img src="img/01lsmanager.png">

<details>


## Part 2. Service Discovery

### В этой главе сымитировал два удаленных сервиса — api и БД, и осуществил между ними подключение через Service Discovery с использованием Consul.

### Создал с помощью Vagrant четыре машины: consul_server, api, manager и db.

<details>
<summary>Vagrant конфиг</summary>

```ruby
Vagrant.configure("2") do |config|
  BOX = "ubuntu-22.04"
  CPU = 4
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

<details>

#### Прокидываем ключи как в part1 на все машины. Устанавливаем ansible и дополнение psql для ansible на manager. Инициализируем роли. 

Создание ролей

```bash
mkdir -p ~/ansible02/roles
cd ~/ansible02
ansible-galaxy init roles/install_consul_server
ansible-galaxy init roles/install_consul_client
ansible-galaxy init roles/install_db
ansible-galaxy init roles/install_hotels_service
```

#### Написал два конфигурационных файла для consul consul_server.hcl, настроить агент как сервер и consul_client.hcl, настроил агент как клиент. Положил на maneger ~/ansible02/consul01/. Скачал бинарники consul и envoy и положил на maneger ~/ansible02/consul01/. Для envoy написал json для db и api.

<details>
<summary>consul сервер, агент и конфиги json для envoy</summary>

```hcl
# consul_server.hcl
datacenter     = "dc1"
node_name      = "consul_server"
data_dir       = "/opt/consul/data"

bind_addr      = "192.168.56.20"
advertise_addr = "192.168.56.20"

server           = true
bootstrap_expect = 1

client_addr = "0.0.0.0"
ui_config { enabled = true }

connect { enabled = true }

# Явно открываем gRPC-порт для Envoy/xDS
ports { grpc = 8502 }
```

```
datacenter = "dc1"

server   = false
data_dir = "/opt/consul/data"

bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"

# IP интерфейса, попадающего в нашу подсеть 192.168.56.0/24
advertise_addr = "{{ GetPrivateInterfaces | include \"network\" \"192.168.56.0/24\" | attr \"address\" }}"

connect  { enabled = true }
addresses { http = "0.0.0.0" }
ports     { grpc = 8502 }

# IP сервера Consul (consul_server): 192.168.56.20
retry_join = ["192.168.56.20"]
```

```json
{
  "service": {
    "name": "hotel",
    "port": 8082,
    "check": { "tcp": "127.0.0.1:8082", "interval": "10s", "timeout": "3s" },
    "connect": {
      "sidecar_service": {
        "proxy": {
          "upstreams": [
            { "destination_name": "postgres", "local_bind_port": 5432 }
          ]
        }
      }
    }
  }
}
```

```json
{
  "service": {
    "name": "postgres",
    "port": 5432,
    "check": {
      "name": "Postgres TCP Check",
      "tcp": "127.0.0.1:5432",
      "interval": "10s",
      "timeout": "1s"
    },
    "connect": {
      "sidecar_service": {
        "port": 21001  
      }
    }
  }
}
```
<details>

#### Загрузил на manager сервис отелей

```bash
vagrant upload ../services/hotel-service /home/vagrant/hotel-service manager 
```

#### Написал ansible inventory.yml  и site.yml

```yml
all:
  vars:
    ansible_user: vagrant
    consul_server_ip: 192.168.56.20
  hosts:
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

```yml
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

#### Написал роль ansible Install_consul_server, которая:
- работает с consul_server;
- копирует consul_server.hcl;
- устанавливает consul и необходимые для consul зависимости;
- запускает сервис consul;

<details>
<summary>tasks Install_consul_server</summary>

```yml
---
- name: Install Consul | Check if Consul binary already installed
  stat:
    path: "{{ consul_bin_path }}"
  register: consul_bin

- name: Install Consul | Copy Consul binary to /usr/local/bin (from {{ base_dir }}/consul)
  copy:
    src: "{{ base_dir }}/consul"
    dest: "{{ consul_bin_path }}"
    mode: "0755"
    owner: root
    group: root

- name: Install Consul | Create Consul dirs
  file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - /opt/consul
    - /opt/consul/data
    - /etc/consul.d

- name: Install Consul | Server config (static HCL)
  copy:
    src: "{{ base_dir }}/consul_server.hcl"
    dest: /etc/consul.d/consul.hcl
    mode: "0644"
  notify:
    - daemon-reload
    - restart consul

- name: Install Consul | Systemd unit for Consul
  copy:
    dest: /etc/systemd/system/consul.service
    mode: "0644"
    content: |
      [Unit]
      Description=Consul Server
      Requires=network-online.target
      After=network-online.target

      [Service]
      ExecStart={{ consul_bin_path }} agent -config-dir=/etc/consul.d -data-dir=/opt/consul
      ExecReload={{ consul_bin_path }} reload
      Restart=on-failure
      RestartSec=5
      LimitNOFILE=65536

      [Install]
      WantedBy=multi-user.target
  notify:
    - daemon-reload
    - restart consul

- name: Install Consul | Ensure Consul started
  service:
    name: consul
    state: started
    enabled: true

- name: Install Consul | Consul reload (apply config)
  command: consul reload
  changed_when: true
```

<details>


#### Написал роль ansible Install_consul_client, которая:
- работает с api и db;
- копирует consul_client.hcl;
- устанавливает consul, envoy и необходимые для consul зависимости;
- запускает сервис consul и consul-envoy;

<details>
<summary>tasks Install_consul_client</summary>

```yml
---
# ==== бинарники ====
- name: Consul | Check binary
  stat:
    path: "{{ consul_bin_path }}"
  register: consul_bin

- name: Consul | Install binary from {{ base_dir }}/consul
  copy:
    src: "{{ base_dir }}/consul"
    dest: "{{ consul_bin_path }}"
    mode: "0755"
    owner: root
    group: root
  when: not consul_bin.stat.exists

- name: Envoy | Check binary
  stat:
    path: "{{ envoy_bin_path }}"
  register: envoy_bin

- name: Envoy | Install binary from {{ base_dir }}/envoy
  copy:
    src: "{{ base_dir }}/envoy"
    dest: "{{ envoy_bin_path }}"
    mode: "0755"
    owner: root
    group: root
  when: not envoy_bin.stat.exists

# ==== директории и конфиг агента ====
- name: Create Consul directories
  file:
    path: "{{ item }}"
    state: directory
    mode: "0755"
  loop:
    - /opt/consul
    - /opt/consul/data
    - /etc/consul.d
    - /etc/consul.d/certs

- name: Put Consul client config (static HCL)
  copy:
    src: "{{ base_dir }}/consul_client.hcl"
    dest: /etc/consul.d/consul.hcl
    mode: "0644"
  notify: restart consul

# ==== регистрации сервисов (JSON) ====
- name: Put hotel service JSON (api only)
  when: inventory_hostname == "api"
  copy:
    src: "{{ base_dir }}/hotel.json"
    dest: /etc/consul.d/hotel.json
    mode: "0644"
  register: hotel_json

- name: Put postgres service JSON (db only)
  when: inventory_hostname == "db"
  copy:
    src: "{{ base_dir }}/postgres.json"
    dest: /etc/consul.d/postgres.json
    mode: "0644"
  register: pg_json

- name: Consul | reload to apply service defs
  command: consul reload
  changed_when: true
  when: (hotel_json is defined and hotel_json.changed) or
        (pg_json   is defined and pg_json.changed)

# ==== systemd: два отдельных сервиса ====
- name: Create Consul systemd unit (client)
  copy:
    dest: /etc/systemd/system/consul.service
    mode: "0644"
    content: |
      [Unit]
      Description=Consul Client
      Requires=network-online.target
      After=network-online.target

      [Service]
      ExecStart={{ consul_bin_path }} agent -config-dir=/etc/consul.d -data-dir=/opt/consul
      ExecReload={{ consul_bin_path }} reload
      Restart=on-failure
      RestartSec=5
      LimitNOFILE=65536

      [Install]
      WantedBy=multi-user.target
  notify: daemon-reload

- name: Create consul-envoy@.service template
  copy:
    dest: /etc/systemd/system/consul-envoy@.service
    mode: "0644"
    content: |
      [Unit]
      Description=Consul Envoy sidecar for %i
      Requires=consul.service
      After=consul.service

      [Service]
      ExecStart={{ consul_bin_path }} connect envoy -sidecar-for %i -envoy-binary {{ envoy_bin_path }} -ignore-envoy-compatibility
      Restart=on-failure
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
  notify: daemon-reload

# ==== стартуем ====
- name: Ensure Consul started
  service:
    name: consul
    state: started
    enabled: true
    daemon_reload: yes
```

<details>


#### Написал роль ansible install_db, которая:
- работает с db;
- устанавливает postgres и запускает его;
- создает базу данных hotels_db;

<details>
<summary>tasks Install_db</summary>

```yml
- name: Apt | install postgres
  apt:
    name:
      - "postgresql-{{ pg_version }}"
      - postgresql-contrib
      - python3-psycopg2
      - acl
    state: present
    update_cache: true

- name: Postgres | ensure started
  service:
    name: postgresql
    enabled: true
    state: started

- name: Postgres | ensure localhost auth
  lineinfile:
    path: "/etc/postgresql/{{ pg_version }}/main/pg_hba.conf"
    regexp: '^host\s+all\s+all\s+127\.0\.0\.1/32\s+.*$'
    line: 'host    all     all     127.0.0.1/32   scram-sha-256'
  notify: Restart Postgres

- name: DB | create user & db
  become_user: postgres
  block:
    - community.postgresql.postgresql_user:
        name: "{{ pg_user }}"
        password: "{{ pg_password }}"
        role_attr_flags: "LOGIN"
    - community.postgresql.postgresql_db:
        name: "{{ pg_db }}"
        owner: "{{ pg_user }}"

- name: Consul | reload
  command: consul reload
  changed_when: true

- name: Sidecar | enable & start
  service:
    name: "consul-envoy@postgres"
    enabled: true
    state: started
    daemon_reload: yes

- name: Postgres | local ping
  become_user: postgres
  community.postgresql.postgresql_query:
    db: "{{ pg_db }}"
    query: "SELECT 1;"
  changed_when: false
```

<details>


#### Написал роль ansible install_hotels_service, которая:
- работает с api;
- копирует исходный код сервиса;
- устанавливает openjdk-8-jdk;
- создает глобальные переменные окружения:
  - POSTGRES_HOST="127.0.0.1";
  - POSTGRES_PORT="5432";
  - POSTGRES_DB="hotels_db";
  - POSTGRES_USER="<имя пользователя>";
  - POSTGRES_PASSWORD="<пароль пользователя>";
- запускает собранный jar-файл командой java -jar <путь до hotel-service>/hotel-service/target/<имя jar-файла>.jar.

<details>
<summary>tasks Install_consul_server</summary>

```yml
---
# ===== Java/Maven =====
- name: Java | prerequisites for PPA
  apt:
    name:
      - wget
      - curl
      - gnupg2
      - software-properties-common
    state: present
    update_cache: true

- name: Java | add OpenJDK PPA (openjdk-r)
  apt_repository:
    repo: "ppa:openjdk-r/ppa"
    state: present
    update_cache: true

- name: Java | install OpenJDK 8 (JRE/JDK для запуска)
  apt:
    name: openjdk-8-jdk
    state: present
    update_cache: true

# Проверяем, есть ли уже готовый jar
- name: App | check runnable jar presence
  stat:
    path: "{{ hotel_dest_dir }}/hotel-service.jar"
  register: hotel_jar

- name: Maven | install (нужен только если будем собирать)
  apt:
    name: maven
    state: present
    update_cache: true
  when: not hotel_jar.stat.exists

# ===== Код приложения / сборка =====
- name: App | create dest dir
  file:
    path: "{{ hotel_dest_dir }}"
    state: directory
    mode: "0755"

# Копируем только если jar ещё не готов
- name: App | copy sources from manager to api
  copy:
    src: "{{ hotel_src_dir_mgr }}/"
    dest: "{{ hotel_dest_dir }}/"
    mode: "0644"
    directory_mode: "0755"
  when: not hotel_jar.stat.exists

# Собираем только если jar ещё не готов
- name: Build | mvn clean package -DskipTests
  command: mvn clean package -DskipTests
  args:
    chdir: "{{ hotel_dest_dir }}"
  environment:
    JAVA_HOME: "/usr/lib/jvm/java-8-openjdk-amd64"
  register: mvn_build
  changed_when: "'BUILD SUCCESS' in mvn_build.stdout or 'BUILD SUCCESS' in mvn_build.stderr"
  when: not hotel_jar.stat.exists

- name: Build | find built jar
  find:
    paths: "{{ hotel_dest_dir }}/target"
    patterns: "*.jar"
    file_type: file
  register: jar_find
  when: not hotel_jar.stat.exists

- name: Build | fail if jar not found
  fail:
    msg: "Не найден jar в {{ hotel_dest_dir }}/target. Проверь сборку Maven."
  when: not hotel_jar.stat.exists and (jar_find.files | length == 0)

- name: Build | place runnable jar
  copy:
    src: "{{ jar_find.files[0].path }}"
    dest: "{{ hotel_dest_dir }}/hotel-service.jar"
    mode: "0755"
    remote_src: true
  when: not hotel_jar.stat.exists
  notify:
    - restart hotel

# ===== Конфиг окружения и юниты =====
- name: Env | write env file
  copy:
    dest: /etc/hotel-service.env
    mode: "0644"
    content: |
      POSTGRES_HOST={{ hotel_pg_host }}
      POSTGRES_PORT={{ hotel_pg_port }}
      POSTGRES_DB={{ hotel_pg_db }}
      POSTGRES_USER={{ hotel_pg_user }}
      POSTGRES_PASSWORD={{ hotel_pg_password }}

- name: Systemd | unit for hotel
  copy:
    dest: /etc/systemd/system/hotel.service
    mode: "0644"
    content: |
      [Unit]
      Description=Hotel Service
      After=network-online.target consul.service
      Wants=network-online.target consul.service
      [Service]
      EnvironmentFile=/etc/hotel-service.env
      WorkingDirectory={{ hotel_dest_dir }}
      ExecStart=/usr/bin/java -jar {{ hotel_dest_dir }}/hotel-service.jar --server.port={{ hotel_port }}
      Restart=on-failure
      [Install]
      WantedBy=multi-user.target
  notify:
    - daemon-reload

# ===== Запуск =====
- name: Services | enable hotel
  service:
    name: hotel
    enabled: true
    state: started
    daemon_reload: yes

- name: Sidecar | enable & start for hotel
  service:
    name: "consul-envoy@hotel"
    enabled: true
    state: started
    daemon_reload: yes
```

<details>

#### Запускаем наш ansible и видим корректную отработку всех play's

```bash
ansible-playbook -i inventory.yml site.yml
```

<img src="img/ansible02play.png">

#### Проверяем работу консул и api через браузер хоста

```
consul
http://127.0.0.1:8500/

api
http://127.0.0.1:8082/
```

<details>
<summary>Скрины consul и api</summary>

<img src="img/consul_work.png">

<img src="img/consul_nodes.png">

<img src="img/consul_api.png">

<img src="img/consul_bd.png">

<img src="img/api_hotel.png">

<details>

#### Проверяем работоспособность CRUD-операций над сервисом отелей. Результаты тестирования.
 
```bash
UUID=$(cat /proc/sys/kernel/random/uuid)

curl -i -X POST http://127.0.0.1:8082/hotels \
  -H "Content-Type: application/json" \
  -d "{
        \"hotelUid\":\"$UUID\",
        \"rooms\":50,
        \"cost\":1500,
        \"name\":\"School21\",
        \"address\":\"Ramonagr\"
      }"

curl -s http://127.0.0.1:8082/hotels | grep -A3 School21 || true

curl -i -X PUT http://127.0.0.1:8082/hotels/1 \
  -H "Content-Type: application/json" \
  -d '{
        "hotelUid":"5ce46f1b-3c46-4227-b333-a35d6c9a00ac",
        "rooms":60,
        "cost":1700,
        "name":"School21 (updated)",
        "address":"Ramonagr, bld. 2"
      }'

curl -i -X DELETE http://127.0.0.1:8082/hotels/1
```

<details>
<summary>CRUD</summary>

<img src="img/CRUD_POST_WORK.png">

<img src="img/CRUD_READ_WORK.png">

<img src="img/CRUD_PUT_FAILED.png">

<img src="img/CRUD_DEL_FAILED.png">

<details>