#!/usr/bin/env bash
# Generates the 5-node FRR lab (Containerlab) in ./lab
# Run:  bash create_lab.sh     then:  cd lab && ./lab.sh up
set -euo pipefail

IMAGE="frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce"

mkdir -p lab
cd lab

# ---------------------------------------------------------------
# Topology file
# ---------------------------------------------------------------
cat > topo.clab.yml <<EOF
name: aiori

topology:
  defaults:
    kind: linux
    image: ${IMAGE}
  nodes:
    r1:
      binds: [configs/r1/frr.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf, logs/r1:/var/log/frr]
    r2:
      binds: [configs/r2/frr.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf, logs/r2:/var/log/frr]
    r3:
      binds: [configs/r3/frr.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf, logs/r3:/var/log/frr]
    r4:
      binds: [configs/r4/frr.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf, logs/r4:/var/log/frr]
    r5:
      binds: [configs/r5/frr.conf:/etc/frr/frr.conf, configs/daemons:/etc/frr/daemons, configs/vtysh.conf:/etc/frr/vtysh.conf, logs/r5:/var/log/frr]
  links:
    - endpoints: ["r1:eth1", "r2:eth1"]   # L12  10.0.12.0/30
    - endpoints: ["r2:eth2", "r3:eth1"]   # L23  10.0.23.0/30
    - endpoints: ["r3:eth2", "r4:eth1"]   # L34  10.0.34.0/30
    - endpoints: ["r4:eth2", "r5:eth1"]   # L45  10.0.45.0/30
    - endpoints: ["r5:eth2", "r1:eth2"]   # L15  10.0.15.0/30
    - endpoints: ["r1:eth3", "r3:eth3"]   # L13  10.0.13.0/30 (chord)
EOF

# ---------------------------------------------------------------
# Machine-readable topology (used later by the diagnosis engine)
# ---------------------------------------------------------------
cat > topology.json <<'EOF'
{
  "nodes": {
    "r1": {"asn": 65001, "loopback": "10.255.0.1"},
    "r2": {"asn": 65002, "loopback": "10.255.0.2"},
    "r3": {"asn": 65003, "loopback": "10.255.0.3"},
    "r4": {"asn": 65004, "loopback": "10.255.0.4"},
    "r5": {"asn": 65005, "loopback": "10.255.0.5"}
  },
  "links": [
    {"id": "L12", "a": "r1", "a_if": "eth1", "a_ip": "10.0.12.1", "b": "r2", "b_if": "eth1", "b_ip": "10.0.12.2"},
    {"id": "L23", "a": "r2", "a_if": "eth2", "a_ip": "10.0.23.1", "b": "r3", "b_if": "eth1", "b_ip": "10.0.23.2"},
    {"id": "L34", "a": "r3", "a_if": "eth2", "a_ip": "10.0.34.1", "b": "r4", "b_if": "eth1", "b_ip": "10.0.34.2"},
    {"id": "L45", "a": "r4", "a_if": "eth2", "a_ip": "10.0.45.1", "b": "r5", "b_if": "eth1", "b_ip": "10.0.45.2"},
    {"id": "L15", "a": "r5", "a_if": "eth2", "a_ip": "10.0.15.1", "b": "r1", "b_if": "eth2", "b_ip": "10.0.15.2"},
    {"id": "L13", "a": "r1", "a_if": "eth3", "a_ip": "10.0.13.1", "b": "r3", "b_if": "eth3", "b_ip": "10.0.13.2"}
  ]
}
EOF

# ---------------------------------------------------------------
# FRR daemons (same for all routers)
# ---------------------------------------------------------------
mkdir -p configs
cat > configs/daemons <<'EOF'
zebra=yes
bgpd=yes
ospfd=yes
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
ospfd_options="  -A 127.0.0.1"
EOF

# ---------------------------------------------------------------
# Per-router FRR config
#   mkrouter <n> <asn> "<if=ip/30 ...>" "<peer_ip=peer_asn ...>"
# ---------------------------------------------------------------
mkrouter() {
  local n=$1 asn=$2 ifaces=$3 peers=$4
  mkdir -p "configs/r$n" "logs/r$n"
  {
    cat <<EOT
frr defaults traditional
hostname r$n
log file /var/log/frr/frr.log informational
log timestamp precision 3
service integrated-vtysh-config
!
interface lo
 ip address 10.255.0.$n/32
 ip ospf area 0
!
EOT
    for i in $ifaces; do
      printf 'interface %s\n ip address %s\n ip ospf area 0\n ip ospf network point-to-point\n ip ospf hello-interval 1\n ip ospf dead-interval 3\n!\n' "${i%%=*}" "${i#*=}"
    done
    cat <<EOT
router ospf
 ospf router-id 10.255.0.$n
 log-adjacency-changes detail
!
router bgp $asn
 bgp router-id 10.255.0.$n
 bgp log-neighbor-changes
 no bgp ebgp-requires-policy
EOT
    for p in $peers; do
      printf ' neighbor %s remote-as %s\n neighbor %s timers 3 9\n' "${p%%=*}" "${p#*=}" "${p%%=*}"
    done
    cat <<EOT
 address-family ipv4 unicast
  network 10.255.0.$n/32
 exit-address-family
!
line vty
!
EOT
  } > "configs/r$n/frr.conf"
}

mkrouter 1 65001 "eth1=10.0.12.1/30 eth2=10.0.15.2/30 eth3=10.0.13.1/30" "10.0.12.2=65002 10.0.15.1=65005 10.0.13.2=65003"
mkrouter 2 65002 "eth1=10.0.12.2/30 eth2=10.0.23.1/30"                   "10.0.12.1=65001 10.0.23.2=65003"
mkrouter 3 65003 "eth1=10.0.23.2/30 eth2=10.0.34.1/30 eth3=10.0.13.2/30" "10.0.23.1=65002 10.0.34.2=65004 10.0.13.1=65001"
mkrouter 4 65004 "eth1=10.0.34.2/30 eth2=10.0.45.1/30"                   "10.0.34.1=65003 10.0.45.2=65005"
mkrouter 5 65005 "eth1=10.0.45.2/30 eth2=10.0.15.1/30"                   "10.0.45.1=65004 10.0.15.2=65001"

touch configs/vtysh.conf
chmod 644 configs/daemons configs/vtysh.conf configs/r*/frr.conf
chmod 777 logs logs/r*

# ---------------------------------------------------------------
# Helper script
# ---------------------------------------------------------------
cat > lab.sh <<'LABSH'
#!/usr/bin/env bash
# Usage: ./lab.sh up | down | status | verify | cli <node> ["vtysh command"] | logs <node> [lines] | shell <node>
set -u
cd "$(dirname "$0")"
LAB=aiori
NODES="1 2 3 4 5"

case "${1:-help}" in
  up)
    sudo containerlab deploy -t topo.clab.yml --reconfigure
    sleep 3
    for n in $NODES; do
      docker exec clab-$LAB-r$n sh -c 'chmod a+rx /var/log/frr; chmod a+r /var/log/frr/*.log' 2>/dev/null
    done
    echo "Wait ~20-30 s for OSPF/BGP to converge, then run: ./lab.sh verify"
    ;;
  fixlogs)
    for n in $NODES; do
      docker exec clab-$LAB-r$n sh -c 'chmod a+rx /var/log/frr; chmod a+r /var/log/frr/*.log'
    done
    echo "Log files on the host are now readable."
    ;;
  down)
    sudo containerlab destroy -t topo.clab.yml --cleanup
    ;;
  status)
    for n in $NODES; do
      echo "================ r$n ================"
      docker exec clab-$LAB-r$n vtysh -c "show ip ospf neighbor" -c "show bgp summary"
    done
    ;;
  verify)
    ok=0; bad=0
    for a in $NODES; do
      for b in $NODES; do
        [ "$a" = "$b" ] && continue
        if docker exec clab-$LAB-r$a ping -c1 -W1 10.255.0.$b >/dev/null 2>&1; then
          ok=$((ok+1))
        else
          bad=$((bad+1)); echo "FAIL: r$a -> r$b (10.255.0.$b)"
        fi
      done
    done
    echo "Loopback pings: $ok ok, $bad failed (expected 20 ok, 0 failed)"
    ;;
  cli)
    node=${2:?node required, e.g. r1}
    if [ $# -ge 3 ]; then
      docker exec clab-$LAB-$node vtysh -c "${*:3}"
    else
      docker exec -it clab-$LAB-$node vtysh
    fi
    ;;
  shell)
    docker exec -it clab-$LAB-${2:?node required} sh
    ;;
  logs)
    docker exec clab-$LAB-${2:?node required} tail -n "${3:-40}" /var/log/frr/frr.log
    ;;
  *)
    sed -n '2p' "$0"
    ;;
esac
LABSH
chmod +x lab.sh

echo
echo "Lab files created in: $(pwd)"
echo "Next:"
echo "  cd lab"
echo "  ./lab.sh up        # deploy the 5 routers"
echo "  ./lab.sh verify    # after ~30 s; expect 20 ok, 0 failed"
echo "  ./lab.sh status    # OSPF neighbours + BGP sessions"
echo "  ./lab.sh logs r1   # FRR log lines for router r1"
