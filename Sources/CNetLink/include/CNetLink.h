#pragma once

#include <netinet/in.h>

#include <linux/ethtool.h>
#include <linux/in6.h>
#include <linux/filter.h>
#include <linux/sockios.h>
#include <linux/if_bridge.h>
#include <linux/netfilter/nfnetlink_log.h>

#include <net/if.h>

#include <netlink/errno.h>
#include <netlink/netlink.h>
#include <netlink/socket.h>
#include <netlink/attr.h>
#include <netlink/msg.h>

#include <netlink/route/addr.h>
#include <netlink/route/class.h>
#include <netlink/route/link.h>
#include <netlink/route/mdb.h>
#include <netlink/route/netconf.h>
#include <netlink/route/qdisc.h>
#include <netlink/route/qdisc/fifo.h>
#include <netlink/route/qdisc/mqprio.h>
#include <netlink/route/qdisc/prio.h>
#include <netlink/route/route.h>
#include <netlink/route/rtnl.h>
#include <netlink/route/rule.h>
#include <netlink/route/link/inet.h>
#include <netlink/route/link/inet6.h>
#include <netlink/route/link/bridge.h>
#include <netlink/route/link/vlan.h>

#include <netlink/netfilter/nfnl.h>
#include <netlink/netfilter/log.h>
#include <netlink/netfilter/log_msg.h>

int rtnl_tc_msg_build(struct rtnl_tc *tc, int type, int flags,
                      struct nl_msg **result);
