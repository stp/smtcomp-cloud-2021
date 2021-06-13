################
FROM ubuntu:20.04 AS horde_base
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
FROM ubuntu:20.04 AS builder
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y cmake build-essential zlib1g-dev libopenmpi-dev git wget unzip build-essential zlib1g-dev iproute2 python3 python3-pip build-essential gfortran wget curl libboost-program-options-dev gcc g++ unzip libopenmpi-dev
RUN gcc --version
RUN g++ --version

# build cmake
# RUN pwd
# RUN wget msoos.org/largefiles/cmake-3.12.0.tar.gz
# RUN tar xzvf cmake-3.12.0.tar.gz
# RUN cd cmake-3.12.0 && ./configure && make -j4
# RUN ./cmake-3.12.0/bin/cmake --version

# build m4ri
RUN pwd
COPY m4ri-20200125.tar.gz m4ri-20200125.tar.gz
#RUN wget msoos.org/largefiles/m4ri-20200125.tar.gz
RUN tar xzvf m4ri-20200125.tar.gz
RUN cd m4ri-20200125 && mkdir -p myinstall && ./configure --prefix=$(pwd)/myinstall && make -j4 VERBOSE=1 && make install


# build cryptominisat
RUN pwd
COPY cryptominisat-devel-ed346b7b0b122498b385ed29b16d209e1b18e235.zip cryptominisat-devel-ed346b7b0b122498b385ed29b16d209e1b18e235.zip
RUN unzip cryptominisat-devel-ed346b7b0b122498b385ed29b16d209e1b18e235.zip
RUN mkdir -p cryptominisat-devel/build && cd cryptominisat-devel/build && M4RI_ROOT_DIR=$(pwd)/../../m4ri-20200125/myinstall cmake -DENABLE_PYTHON_INTERFACE=OFF -DNOVALGRIND=ON -DSTATICCOMPILE=OFF -DCMAKE_BUILD_TYPE=Release -DENABLE_TESTING=OFF -DMANPAGE=OFF .. && make -j4
RUN ls cryptominisat-devel/build/
RUN ldd ./cryptominisat-devel/build/cryptominisat5_mpi
RUN ls /cryptominisat-devel/build/lib/libcryptominisat5.so.5.8
RUN ls /m4ri-20200125/myinstall/lib/libm4ri-0.0.20200125.so

# build minisat
COPY minisat-master-37158a35c62d448b3feccfa83006266e12e5acb7.zip minisat-master-37158a35c62d448b3feccfa83006266e12e5acb7.zip
RUN unzip minisat-master-37158a35c62d448b3feccfa83006266e12e5acb7.zip
RUN mkdir -p minisat-master/build && cd minisat-master/build && cmake .. && make -j4
RUN ls minisat-master/build/

# build STP
RUN apt install -y bison flex
COPY stp-msoos-no-const-as-macro-0535cb5f6a083471e8b588b6aa814073e6425deb.zip stp-msoos-no-const-as-macro-0535cb5f6a083471e8b588b6aa814073e6425deb.zip
RUN unzip stp-msoos-no-const-as-macro-0535cb5f6a083471e8b588b6aa814073e6425deb.zip
RUN mkdir -p stp-msoos-no-const-as-macro/build && cd stp-msoos-no-const-as-macro/build && cmake .. && make -j4
RUN ls stp-msoos-no-const-as-macro/build
RUN ldd stp-msoos-no-const-as-macro/build/stp

################
FROM horde_base AS horde_liaison
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt install -y awscli python3 libopenmpi-dev mpi
COPY --from=builder /cryptominisat-devel/build/cryptominisat5_mpi /cryptominisat-devel/build/cryptominisat5_mpi
COPY --from=builder /cryptominisat-devel/build/lib/libcryptominisat5.so.5.8 /cryptominisat-devel/build/lib/libcryptominisat5.so.5.8
COPY --from=builder /m4ri-20200125/myinstall/lib/libm4ri-0.0.20200125.so /m4ri-20200125/myinstall/lib/libm4ri-0.0.20200125.so
COPY --from=builder /minisat-master/build/libminisat.so.2 /minisat-master/build/libminisat.so.2
COPY --from=builder /stp-msoos-no-const-as-macro/build/stp /stp-msoos-no-const-as-macro/build/stp
COPY --from=builder /stp-msoos-no-const-as-macro/build/lib/libstp.so.2.3 /stp-msoos-no-const-as-macro/build/lib/libstp.so.2.3
COPY --from=builder /lib/x86_64-linux-gnu/libboost_program_options.so.1.71.0 /lib/x86_64-linux-gnu/libboost_program_options.so.1.71.0

ADD make_combined_hostfile.py supervised-scripts/make_combined_hostfile.py
RUN chmod 755 supervised-scripts/make_combined_hostfile.py
ADD mpi-run.sh supervised-scripts/mpi-run.sh
USER horde

# to run locally for SMT:
# ADD square.smt2 square.smt2
# RUN /stp-msoos-no-const-as-macro/build/stp --SMTLIB2 --output-CNF --exit-after-CNF square.smt2
# RUN mpirun -c 16 /cryptominisat-devel/build/cryptominisat5_mpi output_0.cnf 2

# to run locally for CNF:
# ADD mizh-md5-47-3.cnf mizh-md5-47-3.cnf
# RUN mpirun -c 16 /cryptominisat-devel/build/cryptominisat5_mpi mizh-md5-47-3.cnf 2

# to run on AWS
CMD ["/usr/sbin/sshd", "-D", "-f", "/home/horde/.ssh/sshd_config"]
CMD supervised-scripts/mpi-run.sh


