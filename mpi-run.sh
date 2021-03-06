#!/bin/bash
/usr/sbin/sshd -D &

PATH="$PATH:/opt/openmpi/bin/"
BASENAME="${0##*/}"
log () {
  echo "${BASENAME} - ${1}"
}
HOST_FILE_PATH="/tmp/hostfile"
#aws s3 cp $S3_INPUT $SCRATCH_DIR
#tar -xvf $SCRATCH_DIR/*.tar.gz -C $SCRATCH_DIR

sleep 2
echo main node: ${AWS_BATCH_JOB_MAIN_NODE_INDEX}
echo this node: ${AWS_BATCH_JOB_NODE_INDEX}
echo Downloading problem from S3: ${COMP_S3_PROBLEM_PATH}

if [[ "${COMP_S3_PROBLEM_PATH}" == *".xz" ]];
then
  aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} test.cnf.xz
  unxz test.cnf.xz
else
  aws s3 cp s3://${S3_BKT}/${COMP_S3_PROBLEM_PATH} test.cnf
fi

# Set child by default switch to main if on main node container
NODE_TYPE="child"
if [ "${AWS_BATCH_JOB_MAIN_NODE_INDEX}" == "${AWS_BATCH_JOB_NODE_INDEX}" ]; then
  log "Running synchronize as the main node"
  NODE_TYPE="main"
fi

# wait for all nodes to report
wait_for_nodes () {
  log "Running as master node"
  touch $HOST_FILE_PATH
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)

  availablecores=$(nproc)
  log "master details -> $ip:$availablecores"
  log "main IP: $ip"
#  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH
  echo "$ip" >> $HOST_FILE_PATH
  lines=$(ls -dq /tmp/hostfile* | wc -l)
  while [ "${AWS_BATCH_JOB_NUM_NODES}" -gt "${lines}" ]
  do
    cat $HOST_FILE_PATH
    lines=$(ls -dq /tmp/hostfile* | wc -l)

    log "$lines out of $AWS_BATCH_JOB_NUM_NODES nodes joined, check again in 1 second"
    sleep 1
#    lines=$(sort $HOST_FILE_PATH|uniq|wc -l)
  done
  log "OK, all joined now"


  # All of the hosts report their IP and number of processors. Combine all these
  # into one file with the following script:
  supervised-scripts/make_combined_hostfile.py ${ip}
  log "combined  logfile is:"
  cat combined_hostfile

  log "running STP now"
  /usr/bin/time -f %e -o mytime1 /stp-msoos-no-const-as-macro/build/stp --SMTLIB2 --output-CNF --exit-after-CNF test.cnf > stp_output
  log "STP output is:"
  cat stp_output
  if out=`grep "^unsat$" stp_output`; then
      cat > output_0.cnf << EOL
p cnf 1 1
0
EOL
      log "c STP found unsat"
  fi
  if out=`grep "^sat$" stp_output`; then
      cat > output_0.cnf << EOL
p cnf 1 1
1 0
EOL
    log "c STP found sat"
  fi

  # TESTING for STP/output_0.cnf issues?
  log "checking output_0.cnf exists"
  ls -lah output_0.cnf
  # cp test.cnf output_0.cnf


  # REPLACE THE FOLLOWING LINE WITH YOUR PARTICULAR SOLVER
  #  -d=0...7         diversification 0=none, 1=sparse, 2=dense, 3=random, 4=native(plingeling), 5=1&4, 6=sparse-random, 7=6&4, default is 1.
  #  -c=<INT>         use that many cores on each mpi node, default is 1.
  #  -t=<INT>         timelimit in seconds, default is unlimited.
  # time mpirun --mca btl_tcp_if_include eth0 --allow-run-as-root -np ${AWS_BATCH_JOB_NUM_NODES} --hostfile combined_hostfile /hordesat/hordesat  -c=${NUM_PROCESSES} -t=28800 -d=7 test.cnf

  # Cryptominisat run command: mpirun -c 2 ./cryptominisat5_mpi mizh-md5-47-3.cnf.gz 4
  # time mpirun --mca btl_tcp_if_include eth0 --allow-run-as-root -np ${AWS_BATCH_JOB_NUM_NODES} --hostfile combined_hostfile /cryptominisat-devel/build/cryptominisat5_mpi test.cnf 16

  log "Launching MPI system"
  /usr/bin/time -f %e -o mytime2 mpirun --mca btl_tcp_if_include eth0 --allow-run-as-root -np ${AWS_BATCH_JOB_NUM_NODES} --hostfile combined_hostfile /cryptominisat-devel/build/cryptominisat5_mpi output_0.cnf 8 2>/dev/null | tee cms_output
  cat cms_output
  log "MPI system finished"
  t1=`cat mytime1 | tail -n 1`
  t2=`cat mytime2 | tail -n 1`
  t3=`echo "$t1+$t2" | bc`
  echo "time for STP: $t1"
  echo "time for CMS: $t2"
  echo "real ${t3}s"

  if out=`grep "^s UNSATISFIABLE$" cms_output`; then
      echo "unsat"
  fi
  if out=`grep "^s SATISFIABLE$" cms_output`; then
      echo "sat"
  fi
}

# Fetch and run a script
report_to_master () {
  # get own ip and num cpus
  #
  ip=$(/sbin/ip -o -4 addr list eth0 | awk '{print $4}' | cut -d/ -f1)


  availablecores=$(nproc)

  log "I am a child node -> $ip:$availablecores, reporting to the master node -> ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}"

#  echo "$ip slots=$availablecores" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  echo "$ip" >> $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  ping -c 3 ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}
  until scp $HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX} ${AWS_BATCH_JOB_MAIN_NODE_PRIVATE_IPV4_ADDRESS}:$HOST_FILE_PATH${AWS_BATCH_JOB_NODE_INDEX}
  do
    echo "Sleeping 5 seconds and trying again"
  done
  log "done! goodbye"
  ps -ef | grep sshd
  tail -f /dev/null
}
##
#
# Main - dispatch user request to appropriate function
log $NODE_TYPE
case $NODE_TYPE in
  main)
    # TODO run STP here.
    wait_for_nodes "${@}"
    ;;

  child)
    report_to_master "${@}"
    ;;

  *)
    log $NODE_TYPE
    usage "Could not determine node type. Expected (main/child)"
    ;;
esac
