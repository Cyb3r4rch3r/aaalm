##! This script detects a large number of ICMP Time Exceeded messages heading
##! toward hosts that have sent low TTL packets. It generates a notice when the
##! number of ICMP Time Exceeded messages for a source-destination pair exceeds
##! a threshold.

@load base/frameworks/sumstats
@load base/frameworks/signatures
@load-sigs ./detect-low-ttls.sig

redef Signatures::ignored_ids += /traceroute-detector.*/;

module Traceroute;

export {
    redef enum Log::ID += { LOG };

    redef enum Notice::Type += {
        ## Indicates that a host was seen running traceroutes.  For more
        ## detail about specific traceroutes that we run, refer to the
        ## traceroute.log.
        Detected
    };

    ## By default this script requires that any host detected running
    ## traceroutes first send low TTL packets (TTL < 10) to the traceroute
    ## destination host.  Changing this setting to F will relax the
    ## detection a bit by solely relying on ICMP time-exceeded messages to
    ## detect traceroute.
    const require_low_ttl_packets = T &redef;

    ## Defines the threshold for ICMP Time Exceeded messages for a src-dst
    ## pair.  This threshold only comes into play after a host is found to
    ## be sending low TTL packets.
    const icmp_time_exceeded_threshold: double = 1 &redef;

    ## Interval at which to watch for the
    ## :zeek:id:`Traceroute::icmp_time_exceeded_threshold` variable to be
    ## crossed.  At the end of each interval the counter is reset.
    const icmp_time_exceeded_interval = 3min &redef;

    ## The log record for the traceroute log.
    type Info: record {
        ## Timestamp
        ts:    time &log;
        ## Address initiating the traceroute.
        src:   addr &log;
        ## Destination address of the traceroute.
        dst:   addr &log;
        ## Protocol used for the traceroute.
        proto: string &log;

        ## extra bonus!
        emitter: string &log;
    };

    global log_traceroute: event(rec: Traceroute::Info);
}

event zeek_init() &priority=5
{
    print "started";
    Log::create_stream(Traceroute::LOG, [$columns=Info, $ev=log_traceroute, $path="traceroute"]);

    local r1: SumStats::Reducer = [$stream="traceroute.time_exceeded", $apply=set(SumStats::UNIQUE)];
    local r2: SumStats::Reducer = [$stream="traceroute.low_ttl_packet", $apply=set(SumStats::SUM)];
    SumStats::create([$name="traceroute-detection",
                      $epoch=icmp_time_exceeded_interval,
                      $reducers=set(r1, r2),
                      $threshold_val(key: SumStats::Key, result: SumStats::Result) =
                      {
                          # Give a threshold value of zero depending on if the host
                          # sends a low ttl packet.
                          if ( require_low_ttl_packets && result["traceroute.low_ttl_packet"]$sum == 0 )
                              return 0.0;
                          else
                              return result["traceroute.time_exceeded"]$unique+0;
                      },
                      $threshold=icmp_time_exceeded_threshold,
                      $epoch_result(ts: time, key: SumStats::Key, result: SumStats::Result) =
                      {
                          local parts = split_string_n(key$str, /-/, F, 3);
                          local src = to_addr(parts[0]);
                          local dst = to_addr(parts[1]);
                          local proto = parts[2];
                          #print "Filterable", key, result;
                          local t = result["traceroute.time_exceeded"];
                          if (!t?$unique_vals) {
                            return;
                          }

                          local r = t$unique_vals;
                          #print "crossed threshold", key$str, r;
                          for (val in r) {
                              Log::write(LOG, [$ts=ts, $src=src, $dst=dst, $proto=proto, $emitter=val$str]);
                          }
                      }]);
}


# Low TTL packets are detected with a signature.
event signature_match(state: signature_state, msg: string, data: string)
{
    if ( state$sig_id == /traceroute-detector.*/ )
    {
        local s = cat(state$conn$id$orig_h,"-",state$conn$id$resp_h,"-",get_port_transport_proto(state$conn$id$resp_p));

        local p_hdr  = get_current_packet_header();
        local p = get_current_packet();

        if (!p_hdr?$ip) {
            return;
        }

        print "Sig detect match", s, p_hdr$ip$ttl, p;
        SumStats::observe("traceroute.low_ttl_packet", [$str=s], [$num=p_hdr$ip$ttl]);
    }
}

event icmp_time_exceeded(c: connection, icmp: icmp_conn, code: count, context: icmp_context)
{
    local s = cat(context$id$orig_h,"-",context$id$resp_h,"-",get_port_transport_proto(context$id$resp_p));

    local p_hdr  = get_current_packet_header();
    local p = get_current_packet();

    if (!p_hdr?$ip) {
        return;
    }

    print "icmp_time_exceeded", s, icmp$orig_h, p_hdr$ip$ttl, p;

    SumStats::observe("traceroute.time_exceeded", [$str=s], [$str=cat(c$id$orig_h)]);
}
