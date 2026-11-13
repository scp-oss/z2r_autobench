#
# Выносит голосовой UDP (Discord voice + STUN/TURN) на отдельную очередь
# NFQUEUE/отдельный процесс nfqws2, чтобы он не делил один поток с
# TCP TLS (YT/RKN/Discord) и UDP QUIC на очереди 300.
#
# Причина: /proc/net/netfilter/nfnetlink_queue показывал растущий
# queue_user_dropped на очереди 300 (однопоточный nfqws2) во время
# тестов голоса -- пакеты теряются на границе ядро/userspace при
# всплесках нагрузки от остального трафика на той же очереди, что
# выглядит как "DPI то блокирует, то нет" с 30-50 сек разрывами.
#
# Порты здесь -- ТОЛЬКО голосовые/STUN-эксклюзивные (не пересекаются с
# NFQWS2_PORTS_UDP после правки в /opt/zapret2/config, иначе будет
# двойная постановка в очередь одного и того же пакета).
#
VOICE_QNUM=301
VOICE_UDP_PORTS="1400,3478-3481,5349,19294-19344,50000-50099"

VOICE_NFQWS2_OPT="
--lua-init=@/opt/zator/lua/locked.lua
--lua-init=@/opt/zator/lua/rst-guard.lua
--blob=maxru:@/opt/zator/files/fake/fake_tls_1.bin
--blob=google_www:@/opt/zator/files/fake/tls_clienthello_www_google_com.bin
--blob=tls4:@/opt/zator/files/fake/tls_clienthello_4.bin
--blob=custom:@/opt/zator/files/fake/custom_tls.bin
--blob=tls5:@/opt/zator/files/fake/tls_clienthello_5.bin
--blob=quic_google:@/opt/zator/files/fake/quic_initial_www_google_com.bin
--blob=quic5:@/opt/zator/files/fake/quic_5.bin
--blob=discord_fake:@/opt/zator/files/fake/quic_initial_dbankcloud_ru.bin
--blob=stun_fake:@/opt/zator/files/fake/stun.bin
--blob=blob_rdp:@/opt/zator/files/fake/rdp.bin
--blob=fakewgblob:@/opt/zator/files/fake/wg_initial_fake_1.bin
--blob=discord_udp_1:@/opt/zator/files/fake/discord_udp_1.bin
--blob=discord_udp_2:@/opt/zator/files/fake/discord_udp_2.bin
--new
#Стратегии для голосовой связи. В первую очередь Discord, но может ещё для чего поможет
--filter-udp=443,2053,2083,2087,2096,8443,50000-50099,1400,3478-3481,5349,19294-19344
--filter-l7=discord,stun
--lua-desync=circular_locked:key=6:proto=udp:allow_nohost=1:exclude_hostlist=/opt/zator/lists/netrogat.txt
--payload=discord_ip_discovery,stun
--lua-desync=fake:blob=stun_fake:repeats=3:strategy=1 --lua-desync=fake:blob=discord_fake:repeats=3:strategy=1
--lua-desync=fake:blob=discord_udp_1:repeats=10:out_range=-d8:strategy=2 --lua-desync=fake:blob=discord_udp_2:repeats=2:out_range=-d8:strategy=2
--lua-desync=fake:blob=discord_fake:repeats=6:strategy=3
--lua-desync=fake:blob=discord_fake:ipfrag_pos_udp=8:ipfrag_disorder:repeats=6:strategy=4
--lua-desync=fake:blob=discord_fake:out_range=-n4:strategy=5
--lua-desync=fake:blob=discord_fake:out_range=-d2:strategy=6
--lua-desync=fake:blob=0x00:repeats=4:out_range=-d10:strategy=7
--lua-desync=fake:blob=0x00:repeats=6:out_range=-d10:strategy=8
--lua-desync=fake:blob=discord_fake:out_range=-d10:strategy=9
--lua-desync=fake:blob=discord_fake:repeats=6:out_range=-d100:strategy=10
--lua-desync=fake:blob=fake_default_udp:repeats=6:out_range=-d3:strategy=11
--lua-desync=fake:blob=discord_fake:repeats=8:out_range=-d3:strategy=12
--lua-desync=fake:blob=fake_default_udp:repeats=8:out_range=-d4:strategy=13
--lua-desync=fake:blob=fake_default_udp:repeats=6:out_range=-n4:strategy=14
--lua-desync=fake:blob=fake_default_udp:out_range=-n3:strategy=15
--lua-desync=fake:blob=0x00:repeats=4:ip_autottl=0,3-20:ip6_autottl=0,3-20:out_range=-d10:strategy=16
--lua-desync=fake:blob=0x00:repeats=6:out_range=-n2:strategy=17
--lua-desync=fake:blob=quic_google:out_range=-n2:strategy=18
--lua-desync=fake:blob=quic_test:out_range=-d2:strategy=19
--lua-desync=send:repeats=2:ip_autottl=0,3-200:strategy=20 --lua-desync=fake:blob=discord_fake:ip_autottl=0,3-20:out_range=-d100:strategy=20
--lua-desync=send:repeats=2:ip6_autottl=0,3-20:strategy=21 --lua-desync=fake:blob=discord_fake:ip6_autottl=0,3-20:out_range=-d10:strategy=21
--lua-desync=fake:blob=discord_fake:repeats=11:out_range=-d5:strategy=22
--lua-desync=fake:blob=stun_fake:repeats=3:out_range=-d10:strategy=23
--lua-desync=fake:blob=stun_fake:ipfrag_pos_udp=8:ipfrag_disorder:repeats=4:out_range=-d10:strategy=24
--lua-desync=udplen:increment=4:min=20:strategy=25 --lua-desync=fake:blob=0x00:repeats=2:out_range=-d10:strategy=25
--lua-desync=udplen:increment=8:pattern=0x00000000:min=20:strategy=26 --lua-desync=fake:blob=discord_fake:repeats=2:out_range=-d10:strategy=26
--lua-desync=fake:blob=discord_fake:ipfrag_pos_udp=8:repeats=6:out_range=-d10:strategy=27
--lua-desync=fake:blob=quic_google:ipfrag_pos_udp=16:ipfrag_disorder:repeats=6:out_range=-d10:strategy=28
--lua-desync=send:repeats=2:ip_autottl=1,3-20:strategy=29 --lua-desync=fake:blob=0x00:repeats=4:out_range=-d10:strategy=29
--lua-desync=fake:blob=0x00:repeats=10:out_range=-d3:strategy=30
--lua-desync=fake:blob=stun_fake:ip_autottl=0,3-20:ip6_autottl=0,3-20:repeats=4:out_range=-d10:strategy=31
--lua-desync=fake:blob=discord_fake:ipfrag_pos_udp=8:ipfrag_disorder:repeats=8:out_range=-d5:strategy=32
--lua-desync=multidisorder:pos=midsld:blob=maxru:nodrop:ip_autottl=1,3-64:repeats=2:strategy=33
--lua-desync=multidisorder:pos=host:blob=maxru:nodrop:ip_autottl=1,3-64:repeats=2:strategy=34
--lua-desync=multidisorder:pos=midsld:blob=maxru:nodrop:ip_ttl=7:repeats=2:strategy=35
--lua-desync=multisplit:pos=2,1:ip_autottl=1,3-64:repeats=2:strategy=36
--lua-desync=multisplit:pos=2:seqovl=1:ip_autottl=1,3-64:repeats=2:strategy=37
--lua-desync=udplen:increment=4:min=20:ip_autottl=1,3-64:strategy=38
--lua-desync=udplen:increment=4:min=20:ip_autottl=1,3-64:repeats=2:strategy=39
--lua-desync=udplen:increment=8:pattern=0xC3000001:ip_ttl=8:strategy=40
--lua-desync=fakeddisorder:pos=midsld:ip_ttl=9:tcp_ack=-66000:tcp_ts_up:repeats=3:strategy=41
"

# 2026-11-13: опции процесса 301 собираются из ГОЛОСОВОГО блока основного
# NFQWS2_OPT (профиль с circular_locked:key=6) + глобальные --lua-init/--blob
# из его начала. Раньше здесь была статическая копия (41 стратегия), которая
# разошлась с основным конфигом (67): Zenith/promoter правят основной -- копия
# устаревала, а locked.tsv key=6 указывал на номер, который в копии мог
# означать другое. Статическая копия остаётся запасным вариантом.
voice_opt_from_main()
{
	printf '%s\n' "$NFQWS2_OPT" | awk '
		/^[[:space:]]*--new[[:space:]]*$/ { if (inv) exit; seg=""; started=1; next }
		!started && /^[[:space:]]*--(lua-init|blob)=/ { glob = glob $0 "\n"; next }
		!started && /^[[:space:]]*--filter-/ { started=1 }
		{ seg = seg $0 "\n"; if ($0 ~ /circular_locked:key=6:/) inv=1 }
		END { if (inv) printf "%s%s", glob, seg }'
}

zapret_custom_daemons()
{
	# $1 - 1 - run, 0 - stop
	local opt
	opt="$(voice_opt_from_main)"
	if [ -z "$opt" ] || ! printf '%s' "$opt" | grep -q 'strategy='; then
		opt="$VOICE_NFQWS2_OPT"
	fi
	[ "$NFQWS2_ENABLE" = 1 ] && check_bad_ws_options $1 "$opt" && {
		do_nfqws $1 2 "--qnum=$VOICE_QNUM $opt"
	}
}

zapret_custom_firewall()
{
	# $1 - 1 - add, 0 - del
	local QNUM=$VOICE_QNUM
	ipt_do_nfqws_in_out $1 udp "$VOICE_UDP_PORTS" "$NFQWS2_UDP_PKT_OUT" 1 zportvoice
	ipt_do_nfqws_in_out $1 udp "$VOICE_UDP_PORTS" "$NFQWS2_UDP_PKT_IN" 0 zportvoice
}

# nftables (FWTYPE=nftables -- основной режим на NETH-4): до 2026-11-13 хук
# ставил правила только для iptables, и процесс 301 простаивал (голос шёл
# через общую очередь 300 -- то, от чего этот хук и должен был уберечь).
# Вставляем В НАЧАЛО тех же цепочек, что и правила очереди 300: голосовые
# порты уходят в 301 раньше, чем их поймает общее правило.
zapret_custom_firewall_nft()
{
	[ "$NFQWS2_ENABLE" = 1 ] || return 0
	local post pre ports
	post="$(get_postchain)"; pre="$(get_prechain)"
	ports="$(echo "$VOICE_UDP_PORTS" | sed 's/,/, /g')"
	nft_insert_rule "$pre" meta nfproto ipv4 udp sport "{ $ports }" ct reply packets 1-$NFQWS2_UDP_PKT_IN ct mark set ct mark or $DESYNC_MARK queue flags bypass to $VOICE_QNUM comment \"voice-queue\"
	nft_insert_rule "$post" meta nfproto ipv4 udp dport "{ $ports }" ct original packets 1-$NFQWS2_UDP_PKT_OUT meta mark set meta mark or $DESYNC_MARK_POSTNAT ct mark set ct mark or $DESYNC_MARK queue flags bypass to $VOICE_QNUM comment \"voice-queue\"
}

zapret_custom_firewall_nft_flush() { return 0; }
