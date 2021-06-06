################
FROM ubuntu:16.04 AS horde_base
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y openssh-server iproute2 openmpi-bin openmpi-common iputils-ping \
    && mkdir /var/run/sshd \
    && sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd \
    && setcap CAP_NET_BIND_SERVICE=+eip /usr/sbin/sshd \
    && useradd -ms /bin/bash horde \
    && chown -R horde /etc/ssh/ \
    && su - horde -c \
        'ssh-keygen -q -t rsa -f ~/.ssh/id_rsa -N "" \
        && cp ~/.ssh/id_rsa.pub ~/.ssh/authorized_keys \
        && cp /etc/ssh/sshd_config ~/.ssh/sshd_config \
        && sed -i "s/UsePrivilegeSeparation yes/UsePrivilegeSeparation no/g" ~/.ssh/sshd_config \
        && printf "Host *\n\tStrictHostKeyChecking no\n" >> ~/.ssh/config'
WORKDIR /home/horde
ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile
EXPOSE 22

################
FROM ubuntu:16.04 AS builder
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y cmake build-essential zlib1g-dev libopenmpi-dev git wget unzip build-essential zlib1g-dev iproute2 python python-pip build-essential gfortran wget curl libboost-program-options-dev gcc g++ unzip
RUN gcc --version
RUN g++ --version

# build cmake
RUN pwd
RUN wget msoos.org/largefiles/cmake-3.12.0.tar.gz
RUN tar xzvf cmake-3.12.0.tar.gz
RUN cd cmake-3.12.0 && ./configure && make -j4
RUN ./cmake-3.12.0/bin/cmake --version

# build m4ri
RUN pwd
RUN wget msoos.org/largefiles/m4ri-20200125.tar.gz
RUN tar xzvf m4ri-20200125.tar.gz
RUN cd m4ri-20200125 && mkdir -p myinstall && ./configure --prefix=$(pwd)/myinstall && make -j4 VERBOSE=1 && make install


# build cryptominisat
RUN pwd
RUN wget msoos.org/largefiles/cryptominisat-devel-169397b72af155dcfe205410b895b8b200f009bf.zip
RUN unzip cryptominisat-devel-169397b72af155dcfe205410b895b8b200f009bf.zip
RUN mkdir -p cryptominisat-devel/build && cd cryptominisat-devel/build && M4RI_ROOT_DIR=$(pwd)/../../m4ri-20200125/myinstall ../../cmake-3.12.0/bin/cmake -DENABLE_PYTHON_INTERFACE=OFF -DNOVALGRIND=ON -DSTATICCOMPILE=ON -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF -DMANPAGE=OFF .. && make -j4
RUN ls cryptominisat-devel/build/
RUN ldd ./cryptominisat-devel/build/cryptominisat5_mpi

################
FROM horde_base AS horde_liaison
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y awscli python3 mpi
COPY --from=builder /cryptominisat-devel/build/cryptominisat5_mpi /cryptominisat-devel/build/cryptominisat5_mpi
ADD make_combined_hostfile.py supervised-scripts/make_combined_hostfile.py
RUN chmod 755 supervised-scripts/make_combined_hostfile.py
ADD mpi-run.sh supervised-scripts/mpi-run.sh
USER horde
CMD ["/usr/sbin/sshd", "-D", "-f", "/home/horde/.ssh/sshd_config"]
CMD supervised-scripts/mpi-run.sh


