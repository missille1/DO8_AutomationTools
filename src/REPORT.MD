
Прокидывания ключа на node01 и node02 c manager

```bash
# на manager
ssh-keygen -C node1
```

```bash
# на ХОСТЕ
mkdir -p /tmp/ansible01
vagrant ssh manager -c "cat ~/.ssh/id_rsa.pub" > /tmp/ansible01/manager.pub
```

```bash
# на ХОСТЕ
vagrant upload /tmp/ansible01/manager.pub /home/vagrant/manager.pub node01

vagrant ssh node01 -c "cat /home/vagrant/manager.pub >> ~vagrant/.ssh/authorized_keys \
  && rm /home/vagrant/manager.pub"
```

```bash
vagrant ssh manager
ssh vagrant@192.168.56.11 "echo OK && hostname -f"
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