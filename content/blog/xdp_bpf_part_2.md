---
title: "Adventures in XDP/BPF: Part 2"
date: 2020-09-22T22:45:00-05:00
draft: false
---

In [Adventures in XDP/BPF: Part 1](https://tidwellr.com/blog/xdp_bpf/), I outlined my initial thoughts regarding building a full-featured router using XDP. I was finally able to devote some time to this project, so I'm finally going to be able to walk through some code! This is still a work-in-progress, but I've learned how to perform various network functions with XDP. Before diving in too deep, a preface and a quick recap are in order.

## The Project

I'm taking on the challenge of building an XDP router that I can use for my home internet connectivity. Of course, it needs to be able to perform L3 basic routing. It also needs to perform NAT and filter traffic. Below are some basic diagrams that illustrate at a high level how I envision this working.

### UDP
{{< figure src="/images/XDP_BPF/UDP_handling.png" title="" >}}

### TCP Handshake
#### TCP SYN
{{< figure src="/images/XDP_BPF/conntrack_SYN.png" title="" >}}

#### TCP SYN/ACK
{{< figure src="/images/XDP_BPF/conntrack_SYNACK.png" title="" >}}

#### ACK
{{< figure src="/images/XDP_BPF/conntrack_ACK.png" title="" >}}

### Basic Firewall
{{< figure src="/images/XDP_BPF/TCP_drop.png" title="" >}}

I figured the best way to begin iterating on this project was to start with code performs basic routing. It's important to keep in mind how a router handles a packet that it receives on any of its interfaces. I'm going to start with some basic routing 101, then show how this is implemented with XDP.

## Routing 101

When setting up the networking on your laptop, phone, tablet, or server, you will likely encounter a default gateway. The default gateway is the IP address of the router that clients will send all their network traffic to. From there, the router will determine what to do with all that traffic. But what does it mean for clients to "send traffic" to the default gateway? We often wave our hands around this process. It's a detail we take for granted, but if we're going to get into re-implementing portions of the TCP/IP stack it's critical to really understand what is happening here.

Imagine for a moment that you want to perform a google search from your laptop. At a high level, we need to resolve google.com to an IP address and contact a DNS server to get that resolution. But before your laptop can even contact DNS, it needs to direct the packets to the default gateway. The reason we supply an IP address for the default gateway is because we need to find the MAC address of the router if we're going use it as our gateway. You might be familiar with ARP, which is a protocol for resolving an unknown MAC address using a known IP address. The way we get packets to our router (who then forwards them along) is to generate packets with the destination IP set to the host we want send a message to and the MAC address of the router set as the destination MAC address in the ethernet headers. As the packet is passed between routers along the path, each router looks up the MAC address of the next-hop router and re-writes the destination MAC address (and decrements TTL, of course). This process repeats at each hop until the last-mile router can resolve the MAC address of the host we're trying to contact and it can deliver the message to its final destination.

{{< figure src="/images/XDP_BPF/routing-mac-rewrite.png" title="" height="250" width="500">}}

## The XDP Implementation

When handling packets with XDP, our BPF program is going to need to read the destination MAC address of each packet. Like any good ethernet citizen, we'll drop any frame with a destination MAC address that doesn't belong to us. If the destination MAC address matches that of our ingress adapter, we want to pick up the packet and inspect it further to see if we need to route it, re-write some headers, or ultimately drop it. Reading the destination MAC address of the incoming packet is pretty straight-forward. We'll take our xdp_md structure, parse it, and stash the ethernet headers in an ethhdr struct. From there, we get at the destination MAC address by simply referencing the h_dest field of the struct. Here's a little code to illustrate:

```c
/* SPDX-License-Identifier: Apache-2.0 */
#include "xdp_common.h"

SEC("xdp_lan_handler")
int  handle_lan_xdp(struct xdp_md *ctx) {
  void *data_end = (void *)(long)ctx->data_end;
  void *data = (void *)(long)ctx->data;
  struct ethhdr *eth_header;
  struct iphdr *ip_header;
  struct tcphdr *tcp_header;
  struct hdr_cursor nh;
  if (parse_headers(&nh, data_end, &eth_header, &ip_header, &tcp_header) != 0) {
    bpf_printk("Error parsing headers");
    return XDP_PASS;
  }

  bpf_printk("Destination MAC: %u", (__u64)*(eth_header->h_dest));
```

Reading the destination MAC address off the incoming packet is easy enough, so I would have thought reading the MAC address of the adapter our program is bound to would be just as obvious. I found myself pouring over man pages and looking for a BPF that helper that would give me this information. I found myself a little befuddled, there is not an obvious BPF helper that I could call to return me this information. After a lot of head scratching combined with some trial and error, I finally found a solution!

Inside of our XDP program we have a pointer to the ```xdp_md``` struct, which tells us the ```ifindex``` of the interface our program is bound to. We use it by referencing ```ctx->ingress_ifindex```. It may seem a little odd on the surface, but we can actually resolve the MAC address of the ingress interface by performing a lookup into the system's routing table. We have the ```bpf_fib_lookup()``` helper to assist us here. If you're not familiar with the terminology, the FIB (forwarding information base) is essentially another name for the system routing table. If we make a call to ```bpf_fib_lookup()``` with the right parameters, we can pull all the information about the ingress interface (IP address, MAC address, etc.)

Here's some code to demonstrate:

```c
/* SPDX-License-Identifier: Apache-2.0 */
#include "xdp_common.h"

SEC("xdp_lan_handler")
int  handle_lan_xdp(struct xdp_md *ctx) {
  void *data_end = (void *)(long)ctx->data_end;
  void *data = (void *)(long)ctx->data;
  struct ethhdr *eth_header;
  struct iphdr *ip_header;
  struct tcphdr *tcp_header;
  struct hdr_cursor nh;
  struct bpf_fib_lookup ingress_fib_params;
  __builtin_memset(&ingress_fib_params, 0, sizeof(ingress_fib_params));

  // perform a bpf_fib_lookup() to find the MAC and IP addresses of the ingress interface
  ingress_fib_params.family = 2; //AF_INET
  ingress_fib_params.ifindex = ctx->ingress_ifindex;
  int rc = bpf_fib_lookup(ctx, &ingress_fib_params, sizeof(ingress_fib_params), BPF_FIB_LOOKUP_DIRECT);

  // this should succeed, but if for some reason we encounter an error from bpf_fib_lookup(), pass up the stack
  if (rc != BPF_FIB_LKUP_RET_SUCCESS) {
    bpf_printk("bpf_fib_lookup() returned %d, passing up the stack", rc);
    return XDP_PASS;
  }

  bpf_printk("Ingress Interface MAC: %u", (__u64)(ingress_fib_params.smac));
```

I'm still learning my way around XDP/BPF. There may be other ways to look up the MAC address of the ingress adapter that I'm not aware of. This is how I solved the problem, but if someone knows of a more elegant way I would love to hear about it.

Remember how a good ethernet citizen ignores frames with a destination MAC address that doesn't belong to them? Now that we have the MAC addresses from the incoming from and the ingress adapter, we can begin to perform some basic filtering! Let's drop any frames not directed at our router.

```c
/* SPDX-License-Identifier: Apache-2.0 */
#include "xdp_common.h"

static __always_inline int isLocalInterfaceMacAddr(struct bpf_fib_lookup *local_fib_params, struct ethhdr *eth_header) {
	return (__u64)*(local_fib_params->smac) == (__u64)*(eth_header->h_dest);
}

SEC("xdp_lan_handler")
int  handle_lan_xdp(struct xdp_md *ctx) {
  void *data_end = (void *)(long)ctx->data_end;
  void *data = (void *)(long)ctx->data;
  struct ethhdr *eth_header;
  struct iphdr *ip_header;
  struct tcphdr *tcp_header;
  struct hdr_cursor nh;
  struct bpf_fib_lookup ingress_fib_params;
  __builtin_memset(&ingress_fib_params, 0, sizeof(ingress_fib_params));

  // perform a bpf_fib_lookup() to find the MAC and IP addresses of the ingress interface
  ingress_fib_params.family = 2; //AF_INET
  ingress_fib_params.ifindex = ctx->ingress_ifindex;
  int rc = bpf_fib_lookup(ctx, &ingress_fib_params, sizeof(ingress_fib_params), BPF_FIB_LOOKUP_DIRECT);

  // this should succeed, but if for some reason we encounter an error from bpf_fib_lookup(), pass up the stack
  if (rc != BPF_FIB_LKUP_RET_SUCCESS) {
    bpf_printk("bpf_fib_lookup() returned %d, passing up the stack", rc);
    return XDP_PASS;
  }

  if (isLocalInterfaceMacAddr(&ingress_fib_params, eth_header) != 1) {
    bpf_printk("Dropping frame with unknown MAC address");
    return XDP_DROP;
  }
```
Keep in mind that this code will cause us to drop broadcast and multicast frames. Among the side-effects of this simplistic filtering is the fact that ARP and DHCP will not function on the interface we bind this code to. As I iterate, I'll be ensuring that broadcast packets (destination MAC FF:FF:FF:FF:FF:FF) are aren't dropped here. Because I'm aiming for some assistance from the linux network stack, I'll simply be passing L2 broadcasts up the stack by returning ```XDP_PASS``` when a broadcast frame is encountered. I'll be letting the network stack handle ARP, DHCP, and UDP traffic. As I mentioned in part 1, I'm only going to handle TCP traffic with XDP. Everything else gets passed up the stack.

## Conclusion

There is obviously a lot more to flesh out here. I haven't quite gotten to where I can begin to think about connection tracking. In the next post I'll explore interacting with simple BPF maps and how we might generate a 5-tuple hash from the incoming packet to key into a BPF map.

## Links

- https://github.com/rktidwell/xdp-router
- https://man7.org/linux/man-pages/man7/bpf-helpers.7.html
