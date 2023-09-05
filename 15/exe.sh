docker build --network host -f Dockerfile.rhel8 -t koolaji/postgresql:rhel-8-0.1 .
docker rm -f  postgresql
docker run -p 4848:22 --privileged --name postgresql --hostname postgresql --network bridge -e POSTGRESQL_USER=user -e POSTGRESQL_PASSWORD=pass -e POSTGRESQL_DATABASE=db  -d koolaji/postgresql:rhel-8-0.1
sleep 5
docker ps -a
docker logs -f postgresql
#docker exec -ti docker-sshd passwd
