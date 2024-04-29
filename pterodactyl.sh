#!/bin/bash

ubuntu_tasks() {
    blacklist=("example.com" "scorpiohosting.net" "scorpiohosting.com")  

    echo "Enter your email address:"
    read email

    # Extract domain from email address
    domain="${email#*@}"

    # Check if domain is blacklisted
    for blacklisted_domain in "${blacklist[@]}"; do
        if [[ "$domain" == "$blacklisted_domain" ]]; then
            echo "Error: The email domain you provided is blacklisted."
            exit 1
        fi
    done

    # Ask the user for input
    echo "Enter the domain for the site (DO NOT START WITH https) This is for configuring ssl and nginx web server:"
    read domain

    if [[ "$domain" == http://* || "$domain" == https://* ]]; then
        echo "Error: The domain you provided is invalid. Do not start with 'http://' or 'https://'."
        exit 1
    fi

    # Generate a random password with 8 characters
    password=$(openssl rand -base64 12)

    # Output the generated password
    echo "Randomly generated password: $password"

    # Changing the login message
    sudo bash -c "cat <<EOF > /etc/motd
##########################################################################################################################################
This sserver is running Pterodactyl Panel with hostname and SSL Configured! This script was made by Scorpio Hosting.


URL: https://$domain

Admin Login Details:

Username: admin

Master Password: $password

##########################################################################################################################################
EOF"

    # Install dependencies
    echo "Installing dependencies..."
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    curl -fsSL https://packages.redis.io/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
    apt update
    apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server

    # Install Composer
    echo "Installing Composer..."
    curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

    # Download and setup Pterodactyl Panel
    echo "Downloading Panel Files"
    sudo mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/

    # Database Setup!
    echo "Setting Up Database..."
    sudo mysql -u root -p"$password" -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$password';
    CREATE DATABASE panel;
    GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"

    # Environment Setup
    echo "Setting up environment..."
    cd /var/www/pterodactyl/
    cp .env.example .env
    echo "Installing Composer..."
    COMPOSER_HOME=/tmp/composer curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
    cd /var/www/pterodactyl || exit
    composer install --no-dev --optimize-autoloader --no-interaction --no-suggest
    php artisan key:generate --force

    # Environment Configuration
    echo "Setting up environment Database..."
    cd /var/www/pterodactyl/
    php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$password"

    echo "Setting up environment..."
    cd /var/www/pterodactyl/
    php artisan p:environment:setup --author="$email" --url="https://$domain" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui=1 --telemetry=1

    # Database Migration
    echo "Migrating database..."
    php artisan migrate --seed --force
    echo "Done"

    # Making user
    echo "Creating Default Admin..."
    cd /var/www/pterodactyl/
    php artisan p:user:make --username="admin" --name-first="Admin" --name-last="User" --email="$email" --password=$password --admin=1
    echo "DONE!"

    # Set Permissions
    echo "Setting Permissions..."
    sudo chown -R www-data:www-data /var/www/pterodactyl/*
    echo "Done!"

    # Queue Listeners
    echo "Setting up queue listeners..."
    (sudo crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | sudo crontab -
    echo "[Unit]
    Description=Pterodactyl Queue Worker
    After=redis-server.service

    [Service]
    User=www-data
    Group=www-data
    Restart=always
    ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
    StartLimitInterval=180
    StartLimitBurst=30
    RestartSec=5s

    [Install]
    WantedBy=multi-user.target" | sudo tee /etc/systemd/system/pteroq.service > /dev/null
    sudo systemctl enable --now redis-server
    sudo systemctl enable --now pteroq.service

    sudo systemctl start redis-server
    sudo systemctl start --now pteroq.service

    echo "Done"

    # Firewall fixes

    sudo ufw allow 80
    sudo ufw allow 8080
    sudo ufw allow 433

    systemctl stop nginx

    # NGINX Setup with SSL using Certbot
    echo "Setting up Webserber..."
    sudo apt update
    sudo apt install -y certbot
    sudo apt install -y python3-certbot-nginx

    echo "Getting Certificate..."
    sudo certbot certonly --standalone -d $domain -m "$email" --agree-tos --redirect -n

    # Remove default NGINX configuration
    sudo rm /etc/nginx/sites-enabled/default

    # Create a new NGINX configuration file
    cat > /etc/nginx/sites-available/pterodactyl.conf  <<EOF
    server_tokens off;

    server {
        listen 80;
        server_name $domain;
        return 301 https://\$server_name\$request_uri;
    }

    server {
        listen 443 ssl http2;
        server_name $domain;

        root /var/www/pterodactyl/public;
        index index.php;

        access_log /var/log/nginx/pterodactyl.app-access.log;
        error_log  /var/log/nginx/pterodactyl.app-error.log error;


        client_max_body_size 100m;
        client_body_timeout 120s;

        sendfile off;

        ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
        ssl_session_cache shared:SSL:10m;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
        ssl_prefer_server_ciphers on;


        add_header X-Content-Type-Options nosniff;
        add_header X-XSS-Protection "1; mode=block";
        add_header X-Robots-Tag none;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        add_header X-Frame-Options DENY;
        add_header Referrer-Policy same-origin;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ \.php$ {
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass unix:/run/php/php8.1-fpm.sock;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            fastcgi_param HTTP_PROXY "";
            fastcgi_intercept_errors off;
            fastcgi_buffer_size 16k;
            fastcgi_buffers 4 16k;
            fastcgi_connect_timeout 300;
            fastcgi_send_timeout 300;
            fastcgi_read_timeout 300;
            include /etc/nginx/fastcgi_params;
        }

        location ~ /\.ht {
            deny all;
        }
    }
EOF

    # Enable NGINX configuration and restart NGINX
    sudo ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    sudo systemctl restart nginx

    sudo systemctl enable nginx

    sudo systemctl enable redis

    echo "NGINX setup for Pterodactyl Panel with SSL completed!"

    echo "Restarting system"

    sudo bash -c "cat <<EOF > /home/pterodactyl-info
    #####################################################################

    This is running Pterodactyl Panel with hostname and SSL Configured!

    URL: https://$domain

    Admin Login Details:

    Username: admin

    Master Password: $password

    #####################################################################
    EOF"

    reboot now
}






centos8_tasks() {

check_selinux_installed() {
    if [ -x "$(command -v selinuxenabled)" ]; then
        return 0  # SELinux is installed
    else
        return 1  # SELinux is not installed
    fi
}

# Function to run SELinux commands
run_selinux_commands() {
    # Run your SELinux commands here
    echo "SELinux commands are being executed..."

    dnf install -y policycoreutils selinux-policy selinux-policy-targeted setroubleshoot-server setools setools-console mcstrans

    setsebool -P httpd_can_network_connect 1
setsebool -P httpd_execmem 1
setsebool -P httpd_unified 1
}

# Prompt user if they have SELinux installed
prompt_selinux_installed() {
    read -p "Do you have SELinux installed? (yes/no): " selinux_installed
    case "$selinux_installed" in
        [Yy]|[Yy][Ee][Ss])
            if check_selinux_installed; then
                run_selinux_commands
            else
                echo "SELinux is not installed."
            fi
            ;;
        [Nn]|[Nn][Oo])
            echo "SELinux commands will not be executed."
            ;;
        *)
            echo "Invalid input. Please enter yes or no."
            ;;
    esac
}   


    # CentOS tasks
        blacklist=("example.com" "scorpiohosting.net" "scorpiohosting.com")  

    # Extract domain from email address
    domain="${email#*@}"

    # Check if domain is blacklisted
    for blacklisted_domain in "${blacklist[@]}"; do
        if [[ "$domain" == "$blacklisted_domain" ]]; then
            echo "Error: The email domain you provided is blacklisted."
            exit 1
        fi
    done

    if [[ "$domain" == http://* || "$domain" == https://* ]]; then
        echo "Error: The domain you provided is invalid. Do not start with 'http://' or 'https://'."
        exit 1
    fi

    # Generate a random password with 8 characters
    password=$(openssl rand -base64 12)

# Generate a random password with 12 characters
mysql_root_password=$password

# Function to automate MariaDB secure installation
automate_mariadb_secure_installation() {
    # Create an expect script
    expect -c "
    spawn mysql_secure_installation
    expect \"Set root password?\"
    send \"Y\r\"
    expect \"New password:\"
    send \"$mysql_root_password\r\"
    expect \"Re-enter new password:\"
    send \"$mysql_root_password\r\"
    expect \"Remove anonymous users?\"
    send \"Y\r\"
    expect \"Disallow root login remotely?\"
    send \"N\r\"
    expect \"Remove test database and access to it?\"
    send \"Y\r\"
    expect \"Reload privilege tables now?\"
    send \"Y\r\"
    expect eof
    "
}
clear

    echo "Hello and welcome to the CentOS Installer for pterodactyl made by Scorpio Hosting."

    echo "Enter your email address:"
    read email

    echo "Enter the domain for the site (DO NOT START WITH https) This is for configuring ssl and nginx web server:"
    read domain

prompt_selinux_installed

    # Output the generated password
    echo "Randomly generated password: $password"
# Call the function to prompt the user about SELinux

    # Changing the login message
    sudo bash -c "cat <<EOF > /etc/motd
##########################################################################################################################################
This sserver is running Pterodactyl Panel with hostname and SSL Configured! This script was made by Scorpio Hosting.

URL: https://$domain

Admin Login Details:

Username: admin

Master Password: $password

##########################################################################################################################################
EOF"

echo "Welcome to the Pterodacyl installer for CentOS8! This script was made by Scorpio Hosting."

# Installing MariaDB

echo "Installing Depednices"

dnf install -y mariadb mariadb-server

## Start maraidb
systemctl start mariadb
systemctl enable mariadb

## Install Repos
dnf install epel-release
dnf install https://rpms.remirepo.net/enterprise/remi-release-8.rpm
dnf module enable php:remi-8.1

## Get dnf updates
dnf update -y

## Install PHP 8.1
dnf install -y php php-{common,fpm,cli,json,mysqlnd,gd,mbstring,pdo,zip,bcmath,dom,opcache}

echo "Setting up Composer"

dnf install -y nginx

dnf install -y firewalld
systemctl --enable firewalld
systemctl start firewalld
firewall-cmd --add-service=http --permanent
firewall-cmd --add-service=https --permanent 
firewall-cmd --reload

dnf install -y redis

systemctl start redis
systemctl enable redis


dnf install -y zip unzip tar # Required for Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

sudo bash -c "cat <<EOF > /etc/php-fpm.d/www-pterodactyl.conf
[pterodactyl]

user = nginx
group = nginx

listen = /var/run/php-fpm/pterodactyl.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0750

pm = ondemand
pm.max_children = 9
pm.process_idle_timeout = 10s
pm.max_requests = 200
EOF
"

systemctl enable php-fpm
systemctl start php-fpm


# End of Ubuntu 22.04 Installer

sudo bash -c "cat <<EOF > /etc/nginx/conf.d/pterodactyl.con
server_tokens off;

server {
    listen 80;
    server_name $domain;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domain;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;
    
    sendfile off;

    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    # See https://hstspreload.org/ before uncommenting the line below.
    # add_header Strict-Transport-Security "max-age=15768000; preload;";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php-fpm/pterodactyl.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF"

    sudo dnf install -y certbot
    sudo dnf install -y python3-certbot-nginx

    echo "Getting Certificate..."
    sudo certbot certonly --standalone -d $domain -m "$email" --agree-tos --redirect -n


    # Download and setup Pterodactyl Panel
    echo "Downloading Panel Files"
    sudo mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl
    curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
    tar -xzvf panel.tar.gz
    chmod -R 755 storage/* bootstrap/cache/

    # Database Setup!
    echo "Setting Up Database..."
    sudo mysql -u root -p"$password" -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$password';
    CREATE DATABASE panel;
    GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"

    # Environment Setup
    echo "Setting up environment..."
    cd /var/www/pterodactyl/
    cp .env.example .env
    echo "Installing Composer..."
    COMPOSER_HOME=/tmp/composer curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer
    cd /var/www/pterodactyl || exit
    composer install --no-dev --optimize-autoloader --no-interaction --no-suggest
    php artisan key:generate --force

    # Environment Configuration
    echo "Setting up environment Database..."
    cd /var/www/pterodactyl/
    php artisan p:environment:database --host="127.0.0.1" --port="3306" --database="panel" --username="pterodactyl" --password="$password"

    echo "Setting up environment..."
    cd /var/www/pterodactyl/
    php artisan p:environment:setup --author="$email" --url="https://$domain" --timezone="UTC" --cache="redis" --session="redis" --queue="redis" --redis-host="127.0.0.1" --redis-pass="" --redis-port="6379" --settings-ui=1 --telemetry=1

    # Database Migration
    echo "Migrating database..."
    php artisan migrate --seed --force
    echo "Done"

    # Making user
    echo "Creating Default Admin..."
    cd /var/www/pterodactyl/
    php artisan p:user:make --username="admin" --name-first="Admin" --name-last="User" --email="$email" --password=$password --admin=1
    echo "DONE!"

    # Set Permissions
    echo "Setting Permissions..."
    sudo chown -R nginx:nginx /var/www/pterodactyl/*
    echo "Done!" 

    # Queue Listeners
    echo "Setting up queue listeners..."
    (sudo crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | sudo crontab -
    echo "[Unit]
    Description=Pterodactyl Queue Worker
    After=redis-server.service

    [Service]
    User=nginx
    Group=nginx
    Restart=always
    ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
    StartLimitInterval=180
    StartLimitBurst=30
    RestartSec=5s

    [Install]
    WantedBy=multi-user.target" | sudo tee /etc/systemd/system/pteroq.service > /dev/null
    sudo systemctl enable --now redis-server
    sudo systemctl enable --now pteroq.service

    sudo systemctl start redis-server
    sudo systemctl start --now pteroq.service

    echo "Done Rebooting System"

    reboot now

}

display_supported_os() {
    echo "Supported operating systems:"
    echo "1. Ubuntu 20.04 / 22.04"
    echo "2. CentOS 8"
    echo "3. CentOS 9"
#echo "4. Debian 11"
#     echo "4. Rocky Linux 8 / 9"
#     echo "5. AlmaLinux 8 / 9"
 }

# Function to detect the OS and execute tasks accordingly
os_detect_and_execute() {
    # Check if LSB (Linux Standard Base) is installed
    if command -v lsb_release >/dev/null 2>&1; then
        os=$(lsb_release -si)
    else
        echo "Error: LSB (Linux Standard Base) is not installed."
        exit 1
    fi

    echo "We have detected your OS is $os."
    read -p "Is this the correct OS? (yes/no): " confirmation

    case "$confirmation" in
        [Yy]|[Yy][Ee][Ss])
            case "$os" in
                Ubuntu)
                    ubuntu_tasks
                    ;;
                CentOSStream)
                    version=$(lsb_release -sr | cut -d. -f1)
                    if [[ "$version" == "Stream" ]]; then
                        echo "You have CentOSStream."
                        read -p "Please select the CentOS version (8 or 9): " centos_version
                        if [[ "$centos_version" == "8" ]]; then
                            centos8_tasks
                        elif [[ "$centos_version" == "9" ]]; then
                            centos9_tasks
                        else
                            echo "Invalid CentOS version."
                            exit 1
                        fi
                    else
                        case "$version" in
                            8)
                                centos8_tasks
                                ;;
                            9)
                                centos9_tasks
                                ;;
                            *)
                                echo "Unsupported CentOS version: $version"
                                exit 1
                                ;;
                        esac
                    fi
                    ;;
                *)
                    echo "Unsupported operating system: $os"
                    exit 1
                    ;;
            esac
            ;;
        [Nn]|[Nn][Oo])
            display_supported_os
            read -p "Enter the number corresponding to your OS: " choice
            case "$choice" in
                1)
                    os="Ubuntu"
                    ;;
                2)
                    os="CentOSStream"
                    version="8"
                    ;;
                3)
                    os="CentOSStream"
                    version="9"
                    ;;
                *)
                    echo "Invalid choice."
                    exit 1
                    ;;
            esac
            read -p "You have selected $os $version. Are you sure you would like to continue? (yes/no): " confirm_os
            if [[ "$confirm_os" =~ [Yy][Ee][Ss] ]]; then
                echo "Continuing with $os $version tasks..."
                case "$os" in
                    Ubuntu)
                        ubuntu_tasks
                        ;;
                    CentOSStream)
                        case "$version" in
                            8)
                                centos8_tasks
                                ;;
                            9)
                                centos9_tasks
                                ;;
                            *)
                                echo "Unsupported CentOS version: $version"
                                exit 1
                                ;;
                        esac
                        ;;
                    *)
                        echo "Unsupported operating system: $os"
                        exit 1
                        ;;
                esac
            else
                echo "Exiting..."
                exit 1
            fi
            ;;
        *)
            echo "Invalid input. Please enter yes or no."
            exit 1
            ;;
    esac
}


# Execute OS detection and tasks

yum install redhat-lsb-core -y

os_detect_and_execute