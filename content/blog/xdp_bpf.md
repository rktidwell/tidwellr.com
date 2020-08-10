---
title: "Adventures in XDP/BPF: Part 1"
date: 2020-08-09T15:45:00-05:00
draft: false
---

When I first began working with OpenFlow and OVS I was immediately excited that I could program a switch (both physical and virtual!) with something as relatively simple as OpenFlow. I first stumbled upon OVS and OpenFlow in 2012 while delving into OpenStack. Distributed virtual routing (DVR) hadn't been implemented, and people were just beginning to think about it. Naively, I jumped into some PoC's where all networking policy was implemented via OpenFlow rules programmed into OVS. We quickly learned that the stateless and flow-centric nature of OpenFlow didn't lend itself to supporting stateful services like SNAT and or reflexive firewall policies. Others in the OpenStack community were well ahead of me and pushed forward with DVR, using the building blocks of namespaces, iptables, and a small dash of OpenFlow. Of course there are now extensions to OVS that enable some stateful sorts of things, but these didn't exist "back in the day". I had also been thinking about building a small SDN at home that would allow me to experiment and do interesting things on my home network. I was lucky enough to have my day job begin providing those opportunities. Life got busy with kids and a cross-country move as well, so I never got around to taking on a project like this in my "spare" time. Fast forward to 2020, and like a lot of people I found myself stuck inside with a surprising amount of "spare" time. The circumstances of it all are far from ideal (nobody is excited about a pandemic), but this is life right now. Let's make the best of it!

Things like OVS are still around and are a whole lot more stable. I've moved on to a role at work where I focus on things other than OpenStack. New life has also been breathed into a classic technology: Berkley Packet Filters (BPF). The advent of eBPF has placed yet one more landmark on the landscape of programmable datapaths. It turns out, there are tools other than iptables, namespaces, OVS, and OpenFlow in this to understand and experiment with. I've realized I need to catch up with some things. XDP and eBPF seem like a good place to start.

When combined with XDP, eBPF programs can be run inside the context of the network driver. This allows us to enforce networking policies with very little overhead, prior to allocation of an skb. It also provides a means by which policy can be offloaded to a network adapter (when supported by the hardware). This approach performs quite well, and it comes with the added benefit of being native to the linux kernel. Cloudflare has shared some great content on this topic. [How to drop 10 Million packets per second](https://blog.cloudflare.com/how-to-drop-10-million-packets/) and [Cloudflare architecture and how eBPF eats the world](https://blog.cloudflare.com/cloudflare-architecture-and-how-bpf-eats-the-world/) are great reads. eBPF is also quite flexible: eBPF programs can be installed and updated without rebooting the system or losing packets along the way.

One of the poster children for eBPF is the Cilium project. Cilium provides network connectivity for containerized applications. Probably the most popular application of Cilium is as a CNI plugin paired with Kubernetes. Coming across Cilium exposed me to eBPF and XDP and motivated me to learn more. My crazy idea to build a router for my home network using eBPF, XDP, and a simple linux server was born out of working with Cilium. This home router project is still a work-in-progress, but I think providing updates along the way might be interesting. I'm going to simply introduce it here. As this project progresses I'll certainly have more to write about.

## Where To Start?
If you're not familiar with how to write BPF programs, consider spending some time with these links which have been helpful for me:

- https://github.com/xdp-project/xdp-tutorial
- https://prototype-kernel.readthedocs.io/en/latest/bpf/index.html
- https://docs.cilium.io/en/v1.8/bpf/
- http://www.brendangregg.com/ebpf.html

XDP builds on BPF, so some familiarity with BPF and toolchains for it will go a long way toward getting you up to speed with XDP. There are some great tutorials and examples that can be found in the [XDP project tutorials repo](https://github.com/xdp-project/xdp-tutorial). Since I'm still finding my way around I frequently refer to documentation and examples. Anything written by Brendan Gregg about eBPF is also worth your time.

## The Project
I'm trying to build a solution that replaces my Ubiquiti router with a simple linux machine. This may sound daunting to you, and perhaps unnecessary. I agree! What I hope to get out of this exercise is some hands-on experience with XDP/BPF, not compete with Ubiquiti. If I end up with a solution that compels me to replace the gear that I have, that's just a cherry on top. Here are some things I'm keeping in mind:

1. I don't use most of the features provided by Ubiquiti routers on my home network. I can boil things down to the most basic of requirements.
2. Anything that I'm not ready to implement in XDP can be handled with a "full-stack assist" ie return XDP_PASS and let linux handle it. If you're familiar with OpenFlow, this may feel similar to the "forward NORMAL" action. Iterate, iterate, iterate. Build this out incrementally.
2. This exercise is for fun and learning, don't get overwhelmed!

So what exactly do you need out of a home router? When you boil it all down, most people really only need a device that:

- Supports NAT masquerading
- Drops all inbound traffic not associated with a flow known to a connection tracker. It's good to protect yourself from chaos and nefarious actors on the internet.

As far as high-level features go, that's all I really need. Of course, there are a lot of moving parts when you to start to drill down and it all centers around connection tracking. I want to focus on connection tracking in this post, it has turned out to be the first bump in the road.

## Connection Tracking
What do I mean by connection tracking? Connection tracking is simply the act of identifying and following "sessions" flowing across the network. For TCP traffic, this is fairly straight-forward. TCP operates on a state machine, so a service that needs to perform connection tracking can simply follow the actions of the state machine (SYN, SYN-ACK, ACK, RST, FIN) as it processes packets.

So, we can classify network traffic and group it according to a specific conversation between two hosts. What's the utility in that? I suppose surveillance is one application. Firewalls perform connection tracking to enforce stateful security policy. NAT masquerading (AKA SNAT) relies on it behind the scenes too. Chances are the router you have in your house only has a single IPv4 address that is routable on the internet. This address is given to you by your ISP. Chances are you also have more than one device in your home that you want to have access the internet. In case you haven't heard, routable IPv4 addresses are hard to come by these days :wink: . The solution is to perform a network address translation (NAT) in such a way that servers on the internet see all traffic originating from your home as coming from a single IP address. To make this work, your router is performing connection tracking behind the scenes.

In linux, we've had netfilter for a while now. If you've ever used iptables, you've used netfilter. You can use iptables to filter packets and perform NAT. You also get a connection tracker that is handy for use in both SNAT and stateful firewalling. So why not use iptables then? It's solid code that has been around for a while. Well, it turns out that over the years folks have discovered the scalability limits of netfilter. At the same time, XDP/BPF has emerged as a scalable alternative to the current netfilter implementation. Plus, did I mention I'm just trying to learn a little something?

### So, how might we build a connection tracker using XDP/BPF?

Keep in mind that for now, XDP only provides ingress hooks. This means that an XDP program is only invoked when the driver pulls a packet off the RX queue. XDP is not invoked on the transmit path. You'll install XDP programs on both your "WAN" interface and on your "LAN" interface. The XDP code on your LAN interface will see outbound (internet-bound) network traffic, while the XDP code on your WAN interface will only see inbound network traffic (ie packets originating from the internet). There is work going on that enables egress hooks for XDP, but as far as I can tell it isn't available in the mainline kernel yet.

With that background (and a great deal of naivete), I came up with the following ideas for how to do TCP connection tracking with XDP:

- Use the XDP_PASS action to punt the TCP handshake to the linux network stack and let netfilter track the state. Then, use helper functions to access the FIB and conntrack table for established connections, re-write headers, and use XDP_REDIRECT to forward the packet out the appropriate interface completely with an XDP program.
- Classify flows in the XDP context. Then, using a helper function, populate the netfilter conntrack table, re-write headers, and use XDP_REDIRECT to send it on its way. We would lean heavily on netfilter for holding conntrack state for us. This would make a "full-stack" assist with iptables a seamless experience since both XDP and netfilter are working from off of the same data. This is what I REALLY want!
- Do EVERYTHING with XDP. This means we maintain a BPF map containing connection state, use XDP to classify traffic, populate the BPF map, and use XDP_REDIRECT to send it on its way. This is the "XDP the hard way" approach. Great for learning, not an ideal approach for the long haul.

##### Note that each approach requires state to be shared between two XDP programs executing in different contexts

As it turns out, those helper functions I had hoped to build on don't exist. As of today, this leaves the third option as the only feasible design. Upon further investigation into Cilium code and various mailing lists, this is exactly the approach Cilium uses for connection tracking with BPF. People who are smarter and more engaged in this area seem to be aware of the limitations of XDP/BPF, and there's no shortage of good ideas out there to improve the ecosystem around it. While I think we can expect a more complete menu of helpers and better BPF building blocks in the future, they don't exist today. So, we have to take the brute force approach for now. Not the end of the world, did I mention I want to learn a little something? Personally, I would love to see XDP and netfilter work together rather than in their own individual silo as they do today. This is not an original thought, others who have spent more time with these things are thinking about these things too. My crystal ball tells me there are great things on the horizon. There's no shortage of activity in the realm of XDP/BPF!

 I have more questions than answers right now. With the disclaimer that designs can and do fall apart as you implement them, here's how I'm envisioning this would all work:

#### UDP
To keep things simple, I'm thinking of just having XDP punt on all UDP traffic and let the kernel network stack and netfilter deal with it. This is done as part of a basic packet classification step. Whenever we see anything that is not TCP, return XDP_PASS. This passes the packet up the stack and it's no longer my problem to deal with. "Full-stack assist" at work! This means I'll need to configure iptables to handle UDP, but that's not terribly difficult to manage.

{{< figure src="/images/XDP_BPF/UDP_handling.png" title="" >}}

#### TCP
For me, this is where all the intrigue is. Handling TCP traffic this way requires the use of BPF maps, header manipulation, and XDP_DIRECT or XDP_DROP. These are all good things to understand, so being forced into rolling some of this myself checks the education box. I'm waving my hands around a lot of details here, and likely just not accounting for others. With that disclaimer, at a very high level this is what I'm envisioning:

#### SYN
{{< figure src="/images/XDP_BPF/conntrack_SYN.png" title="" >}}

#### SYN/ACK
{{< figure src="/images/XDP_BPF/conntrack_SYNACK.png" title="" >}}

#### ACK
{{< figure src="/images/XDP_BPF/conntrack_ACK.png" title="" >}}

#### Basic Firewall
{{< figure src="/images/XDP_BPF/TCP_drop.png" title="" >}}

## Conclusion
There's a whole lot more that needs to be fleshed out. I'm sure I'm not caught up on some of the latest XDP and BPF development. That's OK, I'm learning! In my next post, I'll be diving in to some code and providing an update on how naive I've been about this whole project.


### A Little More Light Reading That Might Be Of Interest

https://patchwork.kernel.org/patch/11344529/
https://github.com/cilium/cilium/blob/master/bpf/lib/conntrack.h
https://lwn.net/Articles/772896/
https://lists.linuxfoundation.org/pipermail/iovisor-dev/2017-September/001023.html
https://cilium.io/blog/2018/04/17/why-is-the-kernel-community-replacing-iptables/
