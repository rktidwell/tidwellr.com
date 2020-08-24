---
title: "Benchmarking Ceph For Fun and For Profit"
date: 2020-08-24T16:26:01-05:00
draft: false
---

Wait... when you say "Ceph", you mean that storage thingy right? What does that have to do with networking?

Well, I have recently transitioned to a role that is focused on Kubernetes. I'm still doing network-y things, so what gives? I've had a number of projects come my way in this new role, but one that has consumed a great deal of my time is working with storage folks to evaluate the performance of Rook+Ceph. In the last few months I've spent a great deal of time running storage benchmarks against Ceph clusters deployed via Rook with different networking configurations underneath. This has exposed me to CNI plugins like Flannel, Calico, Cilium, and Multus to name a few. Unsurprisingly, the networking configuration you have in your Kubernetes cluster can significantly influence performance. The differences manifest themselves in the form of storage IOPS. Running Ceph on top of Kubernetes gives us a demanding and fairly representative real-world workload to examine. How do various networking settings in Kubernetes affect the performance of Ceph? Let's take a look.

## Preface
What I'm going to discuss assumes Kubernetes is running in some form of "on-prem" environment, directly on hardware you control. In other words, you aren't getting Kubernetes from your friendly neighborhood cloud provider. I recently presented on this topic at Kubecon+CloudNativeCon. If you've seen that presentation, a lot of this will look familiar to you.

### A Word About Rook
If you haven't seen [Rook](https://rook.io/), this is a fascinating project to take a look at. Rook orchestrates the lifcycle of distributed storage systems like Ceph on top of Kubernetes. One of the things you can do with this is provide persistent storage, backed by something like Ceph, to workloads running in your Kubernetes cluster. If you want to run something like an RDBMS like mysql or postgresql, you will want persistent storage. Rook will build you a Ceph cluster and simplify the process exposing volumes to your Kubernetes pods. I've also been exploring what is needed to turn a Rook cluster into a general-purpose storage cluster for use by systems running *outside* of Kubernetes. There are serious networking considerations there too, but that's a topic for another day...

## Benchmarks
While iperf is a common tool for benchmarking the network, my goal was to work with storage engineers to understanding the impact different networking configurations have on a Ceph cluster. With this in mind, the performance of Ceph is actually a nice proxy for the network. For this exercise the hardware, kernel, Kubernetes version, and Rook version were all held constant. The single variable was the networking configuration. By swapping in different CNI plugins and measuring read and write IOPS at various block sizes, we can quantify the overhead imposed by the network against a realistic workload. Instead of measuring packets/second or measuring latency and jitter, I simply measured the performance of an exported Ceph volume inside of a pod using [fio](https://fio.readthedocs.io/en/latest/fio_doc.html). The numbers you see will be expressed in terms of IOPS, but I'll do my best to translate that back into what's happening with the network.

### The Environment
I was lucky enough to have some top-notch hardware at my disposal for this exercise. I had access to hosts with either 25Gb or 100Gb networking at my fingertips. At network speeds like that you'll want to ensure your SSD can keep up with and even outperform the network. Otherwise, you'll effectively be bottlenecked on SSD performance and unable observe the full impact of turning the various networking knobs. This environment had top-of-the-line NVME SSD's in each host, so the storage was plenty fast and we could truly isolate the networking variables.

Here's a diagram of the cluster used for the benchmarking exercise:

{{< figure src="/images/rook_networking/diagram1.png" title="" >}}

### Looking For Latency
When evaluating storage, we tend to talk in terms of IOPS (I/O operations / second). However, when we look under the hood with Ceph the underlying network is an important factor in determining how many IOPS a cluster can sustain. There are two factors to pay attention to:

1. Bandwidth (how wide is the network pipe?)
2. Latency (how long does it take a packet to move from one endpoint to another)

I like to think about this in terms of a highway. When trying to understand how traffic moves on a highway, you will want to know how many lanes the highway has, what the speed limit on the highway is, and how many cars are getting on the highway at the same time.

{{< figure src="/images/rook_networking/highway_w_congested_onramp.png" title="" >}}

We can think of the network like a highway at rush hour. In this analogy, the number of lanes our highway has is our bandwidth. A highway with 4 lanes can move more cars in parallel than a 2-lane highway, but if the on-ramps to our freeway are bottlenecks we may not be able to get enough cars onto the highway to make use of its capacity. Maybe there is a poorly placed stop light at the on-ramp. Perhaps the roads leading to the on-ramp are backed up. Perhaps the number of cars attempting to use the on-ramp is simply higher than what the on-ramp was designed to handle. In any case, the highway has the capacity for all the cars attempting to use the on-ramp once they merge into traffic. The challenge here is maximizing the throughput of the on-ramp.

The phenomenon of a congested on-ramp is a great analogy for latency incurred by the CNI stack on a Kubernetes worker node. We can use a 100Gb/s network fabric, but it doesn't do us much good if the hosts attached to it are incurring significant overhead (latency) moving a packet from a pod to the wire (and vice-versa). Overhead can be incurred by servicing I/O, processing iptables rules in netfilter, or in encapsulating packets with your favorite tunneling protocol (VXLAN, Geneve, IPIP, GRE, etc.). The goal here is to quantify the overhead incurred by these different CNI configurations.

{{< figure src="/images/rook_networking/latency_diagram.png" title="" >}}

With this exercise, we are looking at the latency incurred in the kernel network stack. For purposes of this exercise, the disk access latency is constant. The network fabric latency is also constant.

With this in mind, it would make sense that different CNI configurations should result in different benchmark results. We need to back up that assertion with data, so let's jump into the results.

### Results
Let's look at 1k-8k block sizes. This is going to be the most common range of block sizes. I will dedicate another post to larger block sizes (1m-8m) and what I found there. I found that there are more variables to consider when dealing with larger block sizes, and I think that discussion deserves its own dedicated write-up. We will simply look at this common range of block sizes and how CNI configuration impacts the benchmark results.

#### Read Benchmarks
{{< figure src="/images/rook_networking/read_iops_1k-8k.png" title="" >}}

The first thing I noticed was the gap between encapsulated and unencapsulated configurations. Host networking takes first prize at 66,163 IOPS when using 4k blocks. Slightly behind at 64,728 IOPS is Cilium in direct mode (no overlay). The encapsulated configurations lag behind at anywhere from ~50,000-53,000 IOPS. This is significant, we're looking at ~25% overhead when using VXLAN and IPIP encapsulation for our cluster network.

#### Write Benchmarks
{{< figure src="/images/rook_networking/write_iops_1k-8k.png" title="" >}}

We see a similar pattern when looking at write benchmarks. Host networking again wins first prize from a performance perspective with a 4k block size, delivering 37,213 IOPS. Cilium direct mode is again a close runner-up at 36,271 IOPS. The gap isn't quite as wide on write, but the encapsulated configurations still bring up the rear with ~33,000-34,000 IOPS. The overhead (~10%) on write isn't as significant as it is on read. I suspect that is simply due to the fact that committing writes to the cluster simply involves more overhead in general due to replication. My best guess is that we simply won't see write overheads on the same scale as reads until we scale up the cluster with more clients and Ceph nodes. A *real* Ceph guru would need to weigh in though, I'm a rank amateur when it comes to Ceph. I'm just the network plumber....

## Final Thoughts
Keep in mind that Calico and Cilium are not performing any policy enforcement here. We are simply testing with a basic data path. The gap between host networking and an encapsulated CNI configuration likely widens when we start enforcing network policy. That hypothesis still needs to be tested. We might even see Cilium in direct mode start to lag behind. BPF vs. iptables as the policy enforcement mechanism likely makes a difference too. The take-home message here is that when optimizing for raw performance, encapsulation makes a significant difference when you start looking to optimize your cluster.

From a pure performance perspective, host networking is the front-runner. However, it's important to acknowledge that host networking may not provide you with the desired isolation for your Ceph pods. Fortunately, the Rook community has done some great work to ensure that Rook can run with the Multus CNI plugin. This allows you to use the SR-IOV device plugin (host devices are also supported) and segment traffic from within pods by injecting multiple network interfaces. I did not test with Multus. However, I would expect Multus w/SR-IOV to perform similarly to host networking. SR-IOV by itself doesn't accelerate the data path. It simply enables a single PCI device to be virtualized and appear as multiple adapters. I would expect an SR-IOV virtual function to perform similarly to a dedicated adapter in this environment. Of course I'd like to have numbers to back up that assertion, so benchmarking and scaling up Multus with SR-IOV is on my to-do list.

It was a bit of surprise that network bandwidth wasn't the most important performance factor, although with hindsight that probably should have been obvious in the beginning. With a single Ceph client, I was unable to saturate the 2 x 25Gb/s bond on the client, let alone the 100Gb/s NIC's in the Ceph nodes. To even come close, I had to run benchmarks using the larger 1m-8m block sizes. Even then, we topped out at ~35Gb/s. This means there was plenty of room in the pipe for more disk blocks, the limit to how many IOPS we could push is clearly found in the network stack on each host. Obviously when we scale up the cluster with more clients and Ceph nodes, we will begin to fill up the network pipe. That comes with the concern of how many CPU cycles we lose to processing network traffic. This is not trivial and is another factor I'd like to quantify.

As I keep alluding to, these results aren't representative of a scaled-up environment. Here we have a single client and a rather small Ceph cluster. What happens when we scale up the number of mons, OSD's, and clients? Things might look very different. We might begin to see significant differentiation between Cilium and Calico performance at scale. These are some of the things I'm hoping to look at in the near future.

#### Other Goodies
- [Slides from my presentation at Kubecon+CloudNativeCon](https://static.sched.com/hosted_files/kccnceu20/ef/August-20_Performance-optimization-Rook-on_Kubernetes.pdf)
- [The Kubernetes Network Model](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [Rook Ceph Cluster CRD](https://rook.io/docs/rook/v1.3/ceph-cluster-crd.html)
