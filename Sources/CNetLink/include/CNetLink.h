#pragma once

#include <netinet/in.h>

#include <linux/in6.h>
#include <linux/filter.h>
#include <linux/if_bridge.h>
#include <linux/netfilter/nfnetlink_log.h>

#include <netlink/netlink.h>
#include <netlink/socket.h>
#include <netlink/attr.h>
#include <netlink/msg.h>

#include <netlink/route/addr.h>
#include <netlink/route/class.h>
#include <netlink/route/link.h>
// #include <netlink/route/mdb.h>
#include <netlink/route/netconf.h>
#include <netlink/route/qdisc.h>
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

