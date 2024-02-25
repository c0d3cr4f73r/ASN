#!/usr/bin/env bash

ASN_VERSION="0.76.0"

# ╭──────────────────╮
# │ Helper functions │
# ╰──────────────────╯

docurl(){
	# shellcheck disable=SC2124
	if [ "$ASN_DEBUG" = true ]; then
		parm="$@"
		DebugPrint "${yellow}curl $parm${default}"
	fi
	curl "$@"
}

WhoisASN(){
	found_asname=$(host -t TXT "AS${1}.asn.cymru.com" | grep -v "NXDOMAIN" | awk -F'|' 'NR==1{print substr($NF,2,length($NF)-2)}')
	if [ -n "$found_asname" ]; then
		((json_resultcount++))
		pwhois_full_asn_info=$(whois -h whois.pwhois.org "registry source-as=$1")
		# fetch last org only (in case there are multiple orgs listed for this AS)
		pwhois_asn_info=$(tac <<<"$pwhois_full_asn_info" | grep -m1 -E "^Org-Name")
		pwhois_asn_info+="\n"
		pwhois_asn_info+=$(tac <<<"$pwhois_full_asn_info" | grep -m1 -E "^Create-Date")
		found_holder=$(docurl -m5 -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS$1&sourceapp=nitefood-asn" | jq -r 'select (.data.holder != null) | .data.holder')
		# RIPE usually outputs holder as "ASNAME - actual company name", trim it to just the company name in such cases
		found_holder=$(awk -F' - ' '{ if ( $2 ) {print $2} else {print} }' <<<"$found_holder")
		found_org=$(echo -e "$pwhois_asn_info" | grep -E "^Org-Name:" | cut -d ':' -f 2 | sed 's/^[ \t]*//')
		[[ -z "$found_org" ]] && found_org="N/A"
		found_abuse_contact=$(docurl -m5 -s "https://stat.ripe.net/data/abuse-contact-finder/data.json?resource=AS$asn&sourceapp=nitefood-asn" | jq -r 'select (.data.abuse_contacts[0] != null) | .data.abuse_contacts[0]')
		[[ -z "$found_abuse_contact" ]] && found_abuse_contact="-"
		pwhois_createdate=$(echo -e "$pwhois_asn_info" | grep -E "^Create-Date:" | cut -d ':' -f 2- | sed 's/^[ \t]*//')
		if [ "$JSON_OUTPUT" = true ]; then
			[[ -z "$pwhois_createdate" ]] && found_createdate="" || found_createdate=$(date -d "$pwhois_createdate" "+%Y-%m-%dT%H:%M:%S")
		else
			[[ -z "$pwhois_createdate" ]] && found_createdate="N/A" || found_createdate=$(date -d "$pwhois_createdate" "+%Y-%m-%d %H:%M:%S")
		fi
	fi
}

QueryRipestat(){
	StatusbarMessage "Retrieving BGP data for AS$1 ($found_asname)"
	# BGP routing stats
	ripestat_routing_data=$(docurl -m5 -s "https://stat.ripe.net/data/routing-status/data.json?resource=AS$1&sourceapp=nitefood-asn")
	if [ -n "$ripestat_routing_data" ]; then
		ripestat_ipv4=$(jq -r '.data.announced_space.v4.prefixes' <<<"$ripestat_routing_data")
		ripestat_ipv6=$(jq -r '.data.announced_space.v6.prefixes' <<<"$ripestat_routing_data")
		ripestat_bgp=$(jq -r '.data.observed_neighbours' <<<"$ripestat_routing_data")
	fi
	# BGP neighbours list
	StatusbarMessage "Retrieving peering data for AS$1 ($found_asname)"
	ripestat_neighbours_data=$(docurl -m5 -s "https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS$1&sourceapp=nitefood-asn")
	upstream_peers=$(jq -r '.data.neighbours | sort_by(.power) | reverse[] | select (.type=="left") | .asn' <<<"$ripestat_neighbours_data")
	downstream_peers=$(jq -r '.data.neighbours | sort_by(.power) | reverse[] | select (.type=="right") | .asn' <<<"$ripestat_neighbours_data")
	uncertain_peers=$(jq -r '.data.neighbours | sort_by(.power) | reverse[] | select (.type=="uncertain") | .asn' <<<"$ripestat_neighbours_data")
	if [ "$JSON_OUTPUT" = true ]; then
		json_abuse_contacts=$(docurl -m5 -s "https://stat.ripe.net/data/abuse-contact-finder/data.json?resource=AS$1&sourceapp=nitefood-asn" | jq -cM 'select (.data.abuse_contacts != null) | .data.abuse_contacts')
		[[ -z "$json_abuse_contacts" ]] && json_abuse_contacts="[]"
		json_upstream_peers=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$upstream_peers")
		json_downstream_peers=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$downstream_peers")
		json_uncertain_peers=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$uncertain_peers")
	else
		RESOLVE_COUNT=8
		OUTPUT_PEERS_PER_LINE=4

		# resolve AS names of the first n upstreams
		upstream_peercount=$(echo "$upstream_peers" | wc -l)
		resolved_upstream_peers=""
		count=0
		for peer in $(echo -e "$upstream_peers" | head -n $RESOLVE_COUNT); do
			(( count++ ))
			peername=$(docurl -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS$peer&sourceapp=nitefood-asn" | jq -r '.data.holder' | sed 's/ - .*//' )
			if [ "$IS_ASN_CHILD" = true ]; then
				resolved_upstream_peers+="${greenbg} <a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"background-color: $htmlgreen; color: $htmlblack;\">$peername ($peer)</a> ${default} "
			else
				resolved_upstream_peers+="${greenbg} $peername ($peer) ${default} "
			fi
			[[ $(( count % OUTPUT_PEERS_PER_LINE )) -eq 0 ]] && resolved_upstream_peers+="\n"
		done
		# and add the remaining ones as AS numbers only
		unresolved_peercount=$(( upstream_peercount - RESOLVE_COUNT ))
		if [ "$unresolved_peercount" -ge 1 ]; then
			resolved_upstream_peers+="and more: "
			for peer in $(echo -e "$upstream_peers" | tail -n $unresolved_peercount ); do
				if [ "$IS_ASN_CHILD" = true ]; then
					resolved_upstream_peers+="<a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"color: $htmlgreen;\">$peer</a>${default} "
				else
					resolved_upstream_peers+="${green}${peer}${default} "
				fi
			done
		fi
		upstream_peers="$resolved_upstream_peers"

		# resolve AS names of the first n downstreams
		downstream_peercount=$(echo "$downstream_peers" | wc -l)
		resolved_downstream_peers=""
		count=0
		for peer in $(echo -e "$downstream_peers" | head -n $RESOLVE_COUNT); do
			(( count++ ))
			peername=$(docurl -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS$peer&sourceapp=nitefood-asn" | jq -r '.data.holder' | sed 's/ - .*//' )
			if [ "$IS_ASN_CHILD" = true ]; then
				resolved_downstream_peers+="${yellowbg} <a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"background-color: $htmlyellow; color: $htmlblack;\">$peername ($peer)</a> ${default} "
			else
				resolved_downstream_peers+="${yellowbg} $peername ($peer) ${default} "
			fi
			[[ $(( count % OUTPUT_PEERS_PER_LINE )) -eq 0 ]] && resolved_downstream_peers+="\n"
		done
		# and add the remaining ones as AS numbers only
		unresolved_peercount=$(( downstream_peercount - RESOLVE_COUNT ))
		if [ "$unresolved_peercount" -ge 1 ]; then
			resolved_downstream_peers+="and more: "
			for peer in $(echo -e "$downstream_peers" | tail -n $unresolved_peercount ); do
				if [ "$IS_ASN_CHILD" = true ]; then
					resolved_downstream_peers+="<a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"color: $htmlyellow;\">$peer</a>${default} "
				else
					resolved_downstream_peers+="${yellow}${peer}${default} "
				fi
			done
		fi
		downstream_peers="$resolved_downstream_peers"

		# resolve AS names of the first n uncertains
		uncertain_peercount=$(echo "$uncertain_peers" | wc -l)
		resolved_uncertain_peers=""
		count=0
		for peer in $(echo -e "$uncertain_peers" | head -n $RESOLVE_COUNT); do
			(( count++ ))
			peername=$(docurl -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS$peer&sourceapp=nitefood-asn" | jq -r '.data.holder' | sed 's/ - .*//' )
			if [ "$IS_ASN_CHILD" = true ]; then
				resolved_uncertain_peers+="${lightgreybg} <a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"background-color: $htmllightgray; color: $htmlblack;\">$peername ($peer)</a> ${default} "
			else
				resolved_uncertain_peers+="${lightgreybg} $peername ($peer) ${default} "
			fi
			[[ $(( count % OUTPUT_PEERS_PER_LINE )) -eq 0 ]] && resolved_uncertain_peers+="\n"
		done
		# and add the remaining ones as AS numbers only
		unresolved_peercount=$(( uncertain_peercount - RESOLVE_COUNT ))
		if [ "$unresolved_peercount" -ge 1 ]; then
			resolved_uncertain_peers+="and more: "
			for peer in $(echo -e "$uncertain_peers" | tail -n $unresolved_peercount ); do
				if [ "$IS_ASN_CHILD" = true ]; then
					resolved_uncertain_peers+="<a href=\"/asn_lookup&AS$peer\" class=\"hidden_underline\" style=\"color: $htmlwhite;\">$peer</a>${default} "
				else
					resolved_uncertain_peers+="${white}${peer}${default} "
				fi
			done
		fi
		uncertain_peers="$resolved_uncertain_peers"
	fi

	StatusbarMessage "Retrieving prefix allocations and announcements for AS$1 ($found_asname)"
	ipv4_inetnums=""
	ipv6_inetnums=""
	json_ipv4_other_inetnums=""
	json_ipv6_other_inetnums=""
	ripe_prefixes=$(docurl -m10 -s "https://stat.ripe.net/data/announced-prefixes/data.json?resource=$1&sourceapp=nitefood-asn" | jq -r '.data.prefixes[].prefix')
	json_ripe_prefixes=$(jq -cM --slurp --raw-input 'split("\n") | map(select(length > 0)) | {v4:map(select(contains(":")|not)), v6:map(select(contains(":")))}' <<<"$ripe_prefixes")
	ipv4_ripe_prefixes=$(grep -v ":" <<<"$ripe_prefixes" | grep -Ev "^\n" | sort)
	ipv4_ripe_prefixes_count=$(wc -l <<<"$ipv4_ripe_prefixes")
	ipv6_ripe_prefixes=$(grep ":" <<<"$ripe_prefixes" | grep -Ev "^\n" | sort)
	ipv6_ripe_prefixes_count=$(wc -l <<<"$ipv6_ripe_prefixes")

	# open persistent tcp connection to RIPE whois server
	exec 6<>/dev/tcp/whois.ripe.net/43

	prefixcounter=0
	for prefix in $ipv6_ripe_prefixes; do
		((prefixcounter++))
		StatusbarMessage "Retrieving information for IPv6 prefix $prefixcounter/$ipv6_ripe_prefixes_count"
		# old way (one whois lookup per prefix)
		# inet6nums=$(whois -h whois.ripe.net -- "-T inet6num -K -L --resource $prefix" | \
		#				grep -m2 inet6num | cut -d ':' -f 2- | sed 's/^[ \t]*//')
		# new way (direct tcp connection to whois server with persistent whois connection)
		echo -e "-k -T inet6num -K -L --resource $prefix" >&6
		whoisoutput=""
		# read whois output from the tcp stream line by line
		while IFS= read -r -u 6 whoisoutputline; do
			if [ -n "$whoisoutputline" ]; then
				whoisoutput+="$whoisoutputline\n"
				continue
			fi
			# last line was empty, check if next line is empty too
			# if we get two empty lines in a row, the whois output is finished
			IFS= read -r -u 6 whoisoutputline
			[[ -z "$whoisoutputline" ]] && break || whoisoutput+="$whoisoutputline\n"
		done
		inet6nums=$(echo -e "$whoisoutput" | grep -m2 inet6num | cut -d ':' -f 2- | sed 's/^[ \t]*//')
		for inet6num in $inet6nums; do
			# exclude RIR supernets
			prefix_size=$(echo "$inet6num" | cut -d '/' -f 2)
			[[ "$prefix_size" -le 12 ]] && continue || ipv6_inetnums+="${inet6num}\n"
		done
	done

	prefixcounter=0
	lookedup_parents_cache=""
	for prefix in $ipv4_ripe_prefixes; do
		((prefixcounter++))
		StatusbarMessage "Retrieving information for IPv4 prefix $prefixcounter/$ipv4_ripe_prefixes_count"
		# old way (one whois lookup per prefix)
		# parent_inetnum=$(whois -h whois.ripe.net -- "-T inetnum -K -L --resource  $prefix" | \
		# 				grep -E -m1 "^inetnum" | awk '{print $2"-"$4}' | xargs ipcalc -r 2>/dev/null | grep -v "deaggregate")
		# new way (direct tcp connection to whois server with persistent whois connection)
		echo -e "-k -T inetnum -K -L --resource $prefix" >&6
		whoisoutput=""
		# read whois output from the tcp stream line by line
		while IFS= read -r -u 6 whoisoutputline; do
			if [ -n "$whoisoutputline" ]; then
				whoisoutput+="$whoisoutputline\n"
				continue
			fi
			# last line was empty, check if next line is empty too
			# if we get two empty lines in a row, the whois output is finished
			IFS= read -r -u 6 whoisoutputline
			[[ -z "$whoisoutputline" ]] && break || whoisoutput+="$whoisoutputline\n"
		done
		parent_inetnum=$(echo -e "$whoisoutput" | grep -E -m1 "^inetnum")
		if [ -n "$parent_inetnum" ]; then
			parent_inetnum=$(awk '{print $2"-"$4}' <<<"$parent_inetnum")
			parent_inetnum=$(IpcalcDeaggregate "$parent_inetnum")
			# check if the inetnum containing this prefix is being announced by the same AS as the prefix itself, otherwise
			# it means it's part of a larger supernet by some other AS (e.g. larger carrier allocating own prefix to smaller customer)
			if ! grep -q "$parent_inetnum" <<<"$lookedup_parents_cache"; then
				# this parent inetnum hasn't been looked up yet
				lookedup_parents_cache+="$parent_inetnum\n"
				LookupASNAndRouteFromIP "$parent_inetnum"
				if [ -z "$found_asname" ] || [ "$1" = "$found_asn" ]; then
					# the target AS is also announcing the larger inetnum, or nobody is announcing it. Either way consider it part of the target's resources
					ipv4_inetnums+="$parent_inetnum\n"
				else
					# the larger inetnum is being announced by another AS, only add the announced (smaller) prefix to the list
					ipv4_inetnums+="$prefix\n"
				fi
			else
				# this parent inetnum has already been looked up
				# if it's not present in the list of ipv4_inetnums, it means it's part of a larger supernet by some other AS.
				# therefore we only add the announced (smaller) prefix to the list
				if ! grep -q "$parent_inetnum" <<<"$ipv4_inetnums"; then
					ipv4_inetnums+="$prefix\n"
				fi
			fi
		else
			ipv4_inetnums+="$prefix\n"
		fi
	done
	# close persistent tcp connection to RIPE whois server
	if { true >&6; } 2<> /dev/null; then
		echo -e "-k" >&6
	fi

	if [ "$ADDITIONAL_INETNUM_LOOKUP" = true ]; then
		# fetch further inetnums allocated to this AS from pWhois
		StatusbarMessage "Identifying additional INETNUMs (not announced or announced by other AS) allocated to AS$1"
		pwhois_prefixes=$(PwhoisListPrefixesForOrg "$found_org")
		pwhois_unique_prefixes=$(comm -13 <(echo -e "$ipv4_ripe_prefixes" | sort) <(echo -e "$pwhois_prefixes" | sort))
		pwhois_unique_prefixes=$(comm -13 <(echo -e "$lookedup_parents_cache" | sort) <(echo -e "$pwhois_unique_prefixes" | sort))
		if [ -n "$pwhois_unique_prefixes" ]; then
			pwhois_unique_prefixes_count=$(wc -l <<<"$pwhois_unique_prefixes")
			StatusbarMessage "Identifying origin AS for $pwhois_unique_prefixes_count additional IPv4 prefix(es)"
			# NEW WAY (bulk query to Team Cymru whois server)
			# map the unique prefixes pWhois reported to an array
			mapfile -t pwhois_unique_prefixes_array < <(echo -e "$pwhois_unique_prefixes")
			# assemble a bulk Team Cymru whois lookup query for the new prefixes found in pWhois.
			# we'll check if they're announced by the target AS, by different one, or by no one at all
			# (e.g. target AS has delegated announcements for this prefix to another AS, or is not announcing it)
			# and compile a list to integrate into the allocated IP resources for this AS
			teamcymru_bulk_query="begin\n"
			for prefix in $pwhois_unique_prefixes; do
				teamcymru_bulk_query+="$prefix\n"
			done
			teamcymru_bulk_query+="end"
			prefixcounter=0
			for single_prefix_data in $(echo -e "$teamcymru_bulk_query" | ncat --no-shutdown whois.cymru.com 43 | grep "|" | sed 's/\ *|\ */|/g'); do
				prefix="${pwhois_unique_prefixes_array[$prefixcounter]}"
				prefix_originator_asn=$(echo "$single_prefix_data" | cut -d '|' -f 1)
				if [ "$prefix_originator_asn" = "$1" ]; then
					# prefix originator is same as target AS, add this prefix to the allocated IP resources for this AS
					ipv4_inetnums+="$prefix\n"
				elif [ "$prefix_originator_asn" = "NA" ]; then
					# prefix not announced, add this prefix to the allocated IP resources for this AS with a "not announced" remark
					if [ "$JSON_OUTPUT" = true ]; then
						[[ -n "$json_ipv4_other_inetnums" ]] && json_ipv4_other_inetnums+=","
						json_ipv4_other_inetnums+="{\"prefix\":\"$prefix\",\"origin_asn\":\"\",\"origin_org\":\"\", \"is_announced\":false}"
					elif [ "$IS_ASN_CHILD" = true ]; then
						# skip colors, they will be added along with hyperlinks later
						ipv4_inetnums+=$(printf "%-18s → not announced" "$prefix")
						ipv4_inetnums+="\n"
					else
						ipv4_inetnums+=$(printf "${dim}%-18s → ${red}not announced${default}${green}" "$prefix")
						ipv4_inetnums+="\n"
					fi
				else
					# prefix is announced by a different AS, add this prefix to the allocated IP resources for this AS
					prefix_originator_org=$(echo "$single_prefix_data" | cut -d '|' -f 3)
					if [ "$JSON_OUTPUT" = true ]; then
						[[ -n "$json_ipv4_other_inetnums" ]] && json_ipv4_other_inetnums+=","
						json_ipv4_other_inetnums+="{\"prefix\":\"$prefix\",\"origin_asn\":\"$prefix_originator_asn\",\"origin_org\":\"$prefix_originator_org\", \"is_announced\":true}"
					elif [ "$IS_ASN_CHILD" = true ]; then
						# skip colors, they will be added along with hyperlinks later
						ipv4_inetnums+=$(printf "%-18s → announced by AS%s %s" "$prefix" "${prefix_originator_asn}" "${prefix_originator_org}")
						ipv4_inetnums+="\n"
					else
						ipv4_inetnums+=$(printf "%-18s ${dim}→ announced by ${default}${red}AS%s ${default}${green}%s" "$prefix" "${prefix_originator_asn}" "${prefix_originator_org}")
						ipv4_inetnums+="\n"
					fi
				fi
				((prefixcounter++))
			done
			# OLD WAY (one lookup per prefix)
			# for prefix in $pwhois_unique_prefixes; do
			# 	# found a new prefix in pWhois, check if it's announced by a different AS
			# 	# (e.g. target AS has delegated announcements for this prefix to another AS)
			# 	((prefixcounter++))
			# 	StatusbarMessage "Identifying origin AS for additional IPv4 prefix $prefixcounter/$pwhois_unique_prefixes_count"
			# 	LookupASNAndRouteFromIP "$prefix"
			# 	prefix_originator_asn="$found_asn"
			# 	if [ -z "$prefix_originator_asn" ] || [ "$prefix_originator_asn" = "$1" ]; then
			# 		# prefix originator is same as target AS, or prefix not announced
			# 		# add this prefix to the allocated IP resources for this AS
			# 		ipv4_inetnums+="$prefix\n"
			# 	else
			# 		# this prefix is allocated to target AS, but is being announced by a different AS
			# 		prefix_originator_org=$(docurl -m5 -s "https://stat.ripe.net/data/as-overview/data.json?resource=AS${found_asn}&sourceapp=nitefood-asn" | \
			# 			jq -r 'select (.data.holder != null) | .data.holder' | \
			# 			awk -F' - ' '{ if ( $2 ) {print $2} else {print} }' \
			# 		)
			# 		if [ "$JSON_OUTPUT" = true ]; then
			# 			[[ -n "$json_ipv4_other_inetnums" ]] && json_ipv4_other_inetnums+=","
			# 			json_ipv4_other_inetnums+="{\"prefix\":\"$prefix\",\"origin_asn\":\"$prefix_originator_asn\",\"origin_org\":\"$prefix_originator_org\"}"
			# 		else
			# 			ipv4_inetnums+="$prefix (announced by AS${prefix_originator_asn} - ${prefix_originator_org})\n"
			# 		fi
			# 	fi
			# done
		fi
	fi

	if [ -n "$ipv4_inetnums" ]; then
		ipv4_inetnums=$(echo -e "$ipv4_inetnums" | sort -iu)
		if [ "$IS_ASN_CHILD" = true ] && [ "$JSON_OUTPUT" = false ]; then
			# HTML output
			html=""
			for inetnum in $ipv4_inetnums; do
				if grep -q "announced by" <<<"$inetnum"; then
					# handle special case "<prefix> → announced by AS<asn>"
					actual_inetnum=${inetnum:0:18}
					originator=$(cut -d ' ' -f 7 <<<"$inetnum")
					rest_of_line=$(cut -d ' ' -f 8- <<<"$inetnum")
					html+="<a href=\"/asn_lookup&$actual_inetnum\" class=\"hidden_underline\" style=\"color: $htmlgreen;\">$actual_inetnum</a>"
					html+="<span style=\"font-style: italic; color: $htmldarkgreen\"> → announced by </span>"
					html+="<a href=\"/asn_lookup&$originator\" class=\"hidden_underline\" style=\"color: $htmlred;\">$originator</a> ${rest_of_line}\n"
				elif grep -q "not announced" <<<"$inetnum"; then
					# handle special case "<prefix> → not announced"
					actual_inetnum=${inetnum:0:18}
					html+="<a href=\"/asn_lookup&$actual_inetnum\" class=\"hidden_underline\" style=\"font-style: italic; color: $htmldarkgreen;\">$actual_inetnum</a>"
					html+="<span style=\"font-style: italic; color: $htmldarkred\"> → not announced</span>\n"
				else
					html+="<a href=\"/asn_lookup&$inetnum\" class=\"hidden_underline\" style=\"color: $htmlgreen;\">$inetnum</a>\n"
				fi
			done
			ipv4_inetnums="$html"
		fi
	fi
	if [ -n "$ipv6_inetnums" ]; then
		ipv6_inetnums=$(echo -e "$ipv6_inetnums" | sort -u)
		if [ "$IS_ASN_CHILD" = true ] && [ "$JSON_OUTPUT" = false ]; then
			html=""
			for inet6num in $ipv6_inetnums; do
				html+="<a href=\"/asn_lookup&$inet6num\" class=\"hidden_underline\" style=\"color: $htmlyellow;\">$inet6num</a>\n"
			done
			ipv6_inetnums="$html"
		fi
	fi
	if [ "$JSON_OUTPUT" = true ]; then
		json_ipv4_aggregated_inetnums=$(jq -cM --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$ipv4_inetnums")
		json_ipv6_aggregated_inetnums=$(jq -cM --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$ipv6_inetnums")
	fi
	StatusbarMessage
}

RIPESuggestASN(){
	TRIM_WHITESPACES=false
	input=$(tr '[:lower:]' '[:upper:]' <<<"$1")
	ripe_suggest_output=""
	while true; do
		for input_variation in "${input}" "AS_${input}" "AS-${input}" "${input}_AS" "${input}-AS"; do
			StatusbarMessage "Retrieving suggested ASNs for ${bluebg}${input_variation}${lightgreybg}"
			# lookup input variation (AS_<input>, AS-<input>, <input>_AS, <input>-AS)
			ripe_suggest_output+=$(docurl -s "https://stat.ripe.net/data/searchcomplete/data.json?resource=${input_variation}&sourceapp=nitefood-asn" | \
									jq -r '.data.categories[] | select ( .category == "ASNs" ) | .suggestions[]')
		done
		StatusbarMessage
		if [ -n "$ripe_suggest_output" ]; then
			found_suggestions=$(jq -r '.description' <<<"$ripe_suggest_output" | sort -u)
			for suggestion in $found_suggestions; do
				echo -e "\n${green}$suggestion${default}"
				for suggestion_asn in $(jq -r 'select (.description=="'"$suggestion"'") | .value' <<<"$ripe_suggest_output" | awk 'NR==1{print}'); do
					echo -en "\t${yellow}$suggestion_asn${default} (Rank: "
					GetCAIDARank "${suggestion_asn:2}"
					echo -en "${caida_asrank_recap}"
					echo "${default})"
				done
			done
			echo ""
			return
		elif [ "$TRIM_WHITESPACES" = false ]; then
			TRIM_WHITESPACES=true
			oldinput="$input"
			# shellcheck disable=SC2001
			input=$(echo "$oldinput" | sed 's/[ \t]*//g')
			if [ "$input" = "$oldinput" ]; then
				echo -e "\n${redbg}No suggestions found${default}\n"
				return
			else
				continue
			fi
		else
			echo -e "\n${redbg}No suggestions found${default}\n"
			return
		fi
	done
}

WhoisIP(){
	# $1: (mandatory) IP to lookup
	# $2: (optional) if set to anything, only perform a generic whois lookup (skip pWhois/RPKI/IXP lookups)
	[[ "$JSON_OUTPUT" = true ]] && ((json_resultcount++))
	GENERIC_WHOIS_LOOKUP_ONLY=false
	[[ "$#" -gt 1 ]] && GENERIC_WHOIS_LOOKUP_ONLY=true
	full_whois_data=$(timeout 5 whois "$1" 2>/dev/null)
	network_whois_data=$(echo -e "$full_whois_data" | grep -i -E "^netname:|^orgname:|^org-name:|^owner:|^descr:|^country:")
	# fetch whois inetnum and later compare to cymru prefix, in order to find smallest match (sometimes whois and cymru/pwhois prefix data diverge)
	whois_inetnum=$(IpcalcDeaggregate "$(grep -E -m1 "inet[6]?num|NetRange"<<<"$full_whois_data" | awk '{print $2 $3 $4}')")
	# handle problematic IPs where whois gives out wrong info
	[[ "$whois_inetnum" = "192.168.1.1/32" ]] && whois_inetnum="$found_route"
	ixp_data=""
	ixp_geo=""
	ip_type_json_output=""
	# Check if input is a bogon address
	if [ "$IS_BOGON" = false ]; then
		ip_type_json_output+="\"is_bogon\":false"
		if [ "$GENERIC_WHOIS_LOOKUP_ONLY" = false ]; then
			hostname=$(RdnsLookup "$1")
			[[ -z "$hostname" ]] && hostname="-"
			abuse_whois_data=$(echo -e "$full_whois_data" | grep -E "^OrgAbuseEmail:|^abuse-c:|^% Abuse|^abuse-mailbox:")
			abusecontacts=$(AbuseLookupForPrefix "$abuse_whois_data" "$1")
		fi
		if [ "$UNANNOUNCED_PREFIX" = false ] && [ "$GENERIC_WHOIS_LOOKUP_ONLY" = false ]; then
			# Prefix found in the Team Cymru DB, perform pWhois lookup and CAIDA rank lookup
			PwhoisLookup "$1"
			GetCAIDARank "$found_asn"
		else
			# No data in the Team Cymru DB for this IP (unannounced prefix), or pWhois being skipped
			if [ "$GENERIC_WHOIS_LOOKUP_ONLY" = false ]; then
				[[ -z "$network_whois_data" ]] && PrintErrorAndExit "Error: no data found for $input"
				found_asn="N/A (address not announced)"
				found_asname=""
			fi
			IPGeoRepLookup "$1"
			IPShodanLookup "$1"
			# check if it's an IXP, otherwise fall back to generic whois
			[[ "$GENERIC_WHOIS_LOOKUP_ONLY" = false ]] && IsIXP "$1"
			if [ -n "$ixp_data" ]; then
				if [ "$JSON_OUTPUT" = true ]; then
					pwhois_org="$ixp_data"
				else
					pwhois_org="${bluebg} IXP ${default} ${blue}${ixp_data}${default}"
					ip_type_data=" ${yellowbg} Internet Exchange ${default}"
				fi
			else
				pwhois_org=$(echo -e "$network_whois_data" | grep -i -E "^orgname:|^org-name:|^owner:" | cut -d ':' -f 2 | sed 's/^[ \t]*//' | while read -r line; do echo -n "$line / "; done | sed 's/ \/ $//')
			fi
			[[ -z "$pwhois_org" ]] && pwhois_org="N/A"
			found_route=$(echo -e "$network_whois_data" | grep -i -m2 -E "^descr:" | cut -d ':' -f 2 | sed 's/^[ \t]*//' | while read -r line; do if [ -n "$line" ]; then echo -n "$line / "; fi; done | sed 's/ \/ $//')
			[[ -z "$found_route" ]] && found_route="N/A"
			pwhois_net=$(echo -e "$network_whois_data" | grep -i -E "^netname:" | cut -d ':' -f 2 | sed 's/^[ \t]*//' | while read -r line; do echo -n "$line / "; done | sed 's/ \/ $//')
			[[ -z "$pwhois_net" ]] && pwhois_net="N/A"
			if [ -n "$ixp_geo" ]; then
				pwhois_geo="$ixp_geo"
			elif [ -n "$ip_geo_data" ]; then
				pwhois_geo="$ip_geo_data"
			else
				pwhois_geo=$(echo -e "$network_whois_data" | grep -m1 -i -E "^country:" | cut -d ':' -f 2 | sed 's/^[ \t]*//')
				geo_cc_json_output="$pwhois_geo"
			fi
			[[ -z "$pwhois_geo" ]] && pwhois_geo="N/A"
		fi
	[[ -n "$ixp_data" ]] &&	ip_type_json_output+=",\"is_ixp\":true" || ip_type_json_output+=",\"is_ixp\":false"
	else
		# bogon address, skip lookups
		ip_type_json_output+="\"is_bogon\":true"
		ip_type_json_output+=",\"bogon_type\":\"$json_bogon_type\""
		hostname="-"
		found_asn="-"
		pwhois_org="IANA"
		found_route="N/A"
		abusecontacts="-"
		pwhois_net=$(echo -e "$network_whois_data" | grep -i -E "^netname:" | cut -d ':' -f 2 | sed 's/^[ \t]*//' | while read -r line; do echo -n "$line / "; done | sed 's/ \/ $//')
		found_asname=""
		ip_type_data=" $bogon_tag"
		pwhois_geo="-"
		ip_rep_data="-"
	fi

	indent=$(( longest+4 ))
	if [ -n "$found_asname" ]; then
		output_asname="${green}($found_asname)"
	else
		output_asname=""
	fi
	rpki_output=""
	if [ "$UNANNOUNCED_PREFIX" = false ] && [ "$GENERIC_WHOIS_LOOKUP_ONLY" = false ]; then
		# we skip RPKI lookup in both cases because if SKIP_WHOIS=true then we're being
		# called from TraceASPath, and RPKI lookup will be performed there subsequently
		StatusbarMessage "Checking RPKI validity for ${bluebg}AS${found_asn}${lightgreybg} and prefix ${bluebg}${found_route}${lightgreybg}"
		RPKILookup "$found_asn" "$found_route"
		StatusbarMessage
		[[ "$JSON_OUTPUT" = false ]] && echo ""
	elif [ "$IS_BOGON" = false ]; then
		rpki_output="${red}N/A (address not announced)${default}"
	else
		rpki_output="-"
	fi

	found_subprefix="$found_route"
	whois_routename=""
	# compare cymru net with whois net and pick longer (smaller), while retaining larger for route information.
	# we want to identify subnets to which target IPs belong, even when they aren't
	# announced directly but within a larger route.
	if [ "$found_route" != "N/A" ] && [ "$found_route" != "$whois_inetnum" ]; then
		foundroute_prefixlen=$(cut -d '/' -f 2 <<<"$found_route")
		whois_prefixlen=$(cut -d '/' -f 2 <<<"$whois_inetnum")
		if (( whois_prefixlen > foundroute_prefixlen )) 2>/dev/null; then
			found_subprefix="$whois_inetnum"
			# lookup route name (RIPE)
			whois_routename=$(timeout 5 whois "$found_route" | grep -m1 -E "^descr:" | cut -d ':' -f 2 | sed 's/^ *//g')
		fi
	fi

	if [ "$JSON_OUTPUT" = true ]; then
		# JSON output
		final_json_output+="{"
		final_json_output+="\"ip\":\"$1\","
		grep -q ":" <<<"$1" && ipversion="6" || ipversion="4"
		final_json_output+="\"ip_version\":\"$ipversion\","
		[[ "$hostname" != "-" ]] && final_json_output+="\"reverse\":\"$hostname\","
		final_json_output+="\"org_name\":\"$pwhois_org\","
		# next field can be == $found_route or can be different (smaller) in case the IP belongs to a subnet (of $found_route) that's not routed directly
		final_json_output+="\"net_range\":\"$found_subprefix\","
		final_json_output+="\"net_name\":\"$pwhois_net\","
		if [ -n "$abusecontacts" ] && [ "$abusecontacts" != "-" ]; then
			final_json_output+="\"abuse_contacts\":$abusecontacts,"
		fi
		final_json_output+="\"routing\":{"
		if [ -n "$found_asname" ]; then
			final_json_output+="\"is_announced\":true,"
			final_json_output+="\"as_number\":\"$found_asn\","
			final_json_output+="\"as_name\":\"${found_asname//\"/\\\"}\","
			final_json_output+="\"as_rank\":\"${caida_asrank//\"/\\\"}\","
			final_json_output+="\"route\":\"$found_route\","
			final_json_output+="\"route_name\":\"$whois_routename\","
			final_json_output+="\"roa_count\":\"$roacount_json_output\","
			final_json_output+="\"roa_validity\":\"$roavalidity_json_output\""
		else
			final_json_output+="\"is_announced\":false,"
			if [ "$found_route" != "N/A" ]; then
				final_json_output+="\"net_name\":\"$found_route ($pwhois_net)\""
			else
				final_json_output+="\"net_name\":\"$pwhois_net\""
			fi
		fi
		final_json_output+="},\"type\":{$ip_type_json_output}"
		if [ "$IS_BOGON" != true ]; then
			final_json_output+=",\"geolocation\":{"
			final_json_output+="\"city\":\"$geo_city_json_output\","
			final_json_output+="\"region\":\"$geo_region_json_output\","
			final_json_output+="\"country\":\"$geo_country_json_output\","
			final_json_output+="\"cc\":\"$geo_cc_json_output\""
			final_json_output+="}"
		fi
	else
		# Normal output
		printf "${white}%${longest}s${default} ┌${bluebg}PTR${default} %s\n" "$1" "$hostname"
		if [ "$IS_ASN_CHILD" = true ] && [ -n "$found_asname" ]; then
			summary_asn="<a href=\"/asn_lookup&AS$found_asn\" style=\"color: $htmlred;\">$found_asn</a>"
			ipinfolink="<a href=\"https://ipinfo.io/AS$found_asn/$found_route\" target=\"_blank\" style=\"color: $htmlyellow; font-style: italic;\">ipinfo.io</a>"
			summary_ipinfo=" <span style=\"font-size: 75%; color: $htmlyellow;\">($ipinfolink🔗)</span>"
		else
			summary_asn="$found_asn"
			summary_ipinfo=""
		fi
		printf "${white}%${indent}s${bluebg}ASN${default} ${red}%s %s${default}\n" "├" "$summary_asn" "$output_asname"
		[[ "$UNANNOUNCED_PREFIX" = false ]] && printf "${white}%${indent}s${bluebg}RNK${default} ${default}%s${default}\n" "├" "$caida_asrank_recap"
		printf "${white}%${indent}s${bluebg}ORG${default} ${green}%s${default}\n" "├" "$pwhois_org"
		if [ "$found_subprefix" != "$found_route" ]; then
			# target IP belongs to a subnet announced within a larger route
			printf "${white}%${indent}s${bluebg}NET${default} ${yellow}%s (%s)${default}\n" "├" "$found_subprefix" "$pwhois_net"
			[[ -n "$whois_routename" ]] && whois_routename=" ($whois_routename)"
			printf "${white}%${indent}s${bluebg}ROU${default} ${yellow}%s%s%s${default}\n" "├" "$found_route" "$whois_routename" "$summary_ipinfo"
		else
			# target IP belongs to a subnet announced directly
			printf "${white}%${indent}s${bluebg}NET${default} ${yellow}%s (%s)%s${default}\n" "├" "$found_subprefix" "$pwhois_net" "$summary_ipinfo"
		fi
		printf "${white}%${indent}s${bluebg}ABU${default} ${blue}%s${default}\n" "├" "$abusecontacts"
		printf "${white}%${indent}s${bluebg}ROA${default} %s\n" "├" "$rpki_output"
		[[ -n "$ip_type_data" ]] && printf "${white}%${indent}s${bluebg}TYP${default}%s\n" "├" "${ip_type_data}"
		printf "${white}%${indent}s${bluebg}GEO${default} ${magenta}%s${default}" "├" "$pwhois_geo"
		if [ "$IS_ASN_CHILD" = true ] && [ -n "$flag_icon_cc" ]; then
			# signal to the parent connhandler the correct country flag to display for this IP
			echo -n " #COUNTRYCODE $flag_icon_cc"
		fi
		printf "\n"
	fi
}

IsBogon(){
	bogon_tag=""
	IS_BOGON=false
	# Bogon regex patterns
	localhostregex='(^127\.)' # RFC 1122 localhost
	thisnetregex='(^0\.)' # RFC 1122 'this' network
	privateregex='(^192\.168\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^::1$)|(^[fF][cCdD])' # RFC 1918 private space - cheers https://stackoverflow.com/a/11327345/5377165
	cgnregex='(^100\.6[4-9]\.)|(^100\.[7-9][0-9]\.)|(^100\.1[0-1][0-9]\.)|(^100\.12[0-7]\.)' # RFC 6598 Carrier grade nat space
	llregex='(^169\.254\.)' # RFC 3927 link local
	ietfprotoregex='(^192\.0\.0\.)' # IETF protocol assignments
	testnetregex='(^192\.0\.2\.)|(^198\.51\.100\.)|(^203\.0\.113\.)' # RFC 5737 TEST-NET
	benchmarkregex='(^192\.1[8-9]\.)' # RFC 2544 Network interconnect device benchmark testing
	sixtofouranycast='(^192\.88\.99\.)' # RFC 7526 6to4 anycast relay
	multicastregex='(^22[4-9]\.)|(^23[0-9]\.)' # Multicast
	reservedregex='(^24[0-9]\.)|(^25[0-5]\.)' # Reserved for future use/limited broadcast (255.255.255.255)

	if [[ "$1" =~ $localhostregex ]]; then
		bogon_tag="rfc1122 (Localhost)"
		MTR_TRACING=false
	elif [[ "$1" =~ $thisnetregex ]]; then
		bogon_tag="rfc1122 ('this' network)"
		MTR_TRACING=false
	elif [[ "$1" =~ $privateregex ]]; then
		bogon_tag="rfc1918 (Private Space)"
	elif [[ "$1" =~ $cgnregex ]]; then
		bogon_tag="rfc6598 (CGN Space)"
	elif [[ "$1" =~ $llregex ]]; then
		bogon_tag="rfc3927 (Link-Local)"
	elif [[ "$1" =~ $ietfprotoregex ]]; then
		bogon_tag="(Reserved for IETF protocol assignments)"
	elif [[ "$1" =~ $testnetregex ]]; then
		bogon_tag="rfc5737 (Reserved for Test Networks)"
	elif [[ "$1" =~ $benchmarkregex ]]; then
		bogon_tag="rfc2544 (Reserved for Network device benchmark testing)"
	elif [[ "$1" =~ $sixtofouranycast ]]; then
		bogon_tag="rfc7526 (6to4 anycast relay)"
	elif [[ "$1" =~ $multicastregex ]]; then
		bogon_tag="(Multicast Address)"
		MTR_TRACING=false
	elif [[ "$1" =~ $reservedregex ]]; then
		bogon_tag="(Reserved Address)"
		MTR_TRACING=false
	fi
	if [ -n "$bogon_tag" ]; then
		IS_BOGON=true
		json_bogon_type="$bogon_tag"
		bogon_tag="${yellowbg} BOGON ${default} ${bogon_tag}"
	fi
}

LookupASNAndRouteFromIP(){
	found_asn=""
	found_route=""
	found_asname=""
	IsBogon "$1"
	if [ "$IS_BOGON" = false ]; then
		if echo "$1" | grep -q ':'; then
			# whois query for IPv6 addresses
			output=$(whois -h whois.cymru.com " -f -p -u $1" | sed 's/\ *|\ */|/g')
			found_asn=$(echo "$output" | awk -F'[|]' 'NR==1{print $1}')
			if [ "$found_asn" = "NA" ]; then
				# Team Cymru has no data for this IPv6. Inform WhoisIP() that we will have to fall back to a generic whois lookup.
				found_asn=""
				UNANNOUNCED_PREFIX=true
			else
				found_asname=$(echo "$output" | awk -F'[|]' 'NR==1{print $4}')
				found_route=$(echo "$output" | awk -F'[|]' 'NR==1{print $3}')
				UNANNOUNCED_PREFIX=false
				# lookup CAIDA rank info for the origin AS
				GetCAIDARank "$found_asn"
			fi
		else
			# Query RIPEStat for IPv4 addresses
			output=$(docurl -m5 -s "https://stat.ripe.net/data/prefix-overview/data.json?resource=$1&sourceapp=nitefood-asn")
			if jq -r '.data.announced' <<<"$output" | grep -q "true"; then
				found_asn=$(jq -r '.data.asns[0].asn' <<<"$output")
				found_asname=$(jq -r '.data.asns[0].holder' <<<"$output")
				# look up the country this ASN is located in
				country=$(docurl -m5 -s "https://stat.ripe.net/data/rir-stats-country/data.json?resource=AS${found_asn}" | jq -r '.data.located_resources[0].location')
				[[ "$country" != "null" ]] && found_asname="${found_asname}, ${country}"
				found_route=$(jq -r '.data.resource' <<<"$output")
				UNANNOUNCED_PREFIX=false
			else
				# RIPEStat has no data for this IPv4. Fallback to Team Cymru DNS query (faster than whois)
				rev=$(echo "$1" | cut -d '/' -f 1 | awk -F'.' '{printf $4 "." $3 "." $2 "." $1}')
				output=$(host -t TXT "$rev.origin.asn.cymru.com" | awk -F'"' 'NR==1{print $2}' | sed 's/\ *|\ */|/g')
				found_asn=$(echo "$output" | awk -F'[|]' 'NR==1{print $1}' | cut -d ' ' -f 1) # final cut gets first origin AS only if cymru has multiple
				if [ -n "$found_asn" ]; then
					found_asname=$(host -t TXT "AS$found_asn.asn.cymru.com" | grep -v "NXDOMAIN" | awk -F'|' 'NR==1{print substr($NF,2,length($NF)-2)}')
					found_route=$(echo "$output" | awk -F'[|]' 'NR==1{print $2}')
					UNANNOUNCED_PREFIX=false
				else
				# Team Cymru has no data for this IPv4 either. Inform WhoisIP() that we will have to fall back to a generic whois lookup.
					UNANNOUNCED_PREFIX=true
				fi
			fi
		fi
	else
		# bogon address, consider it unannounced
		UNANNOUNCED_PREFIX=true
	fi
}

ResolveHostnameToIPList(){
	raw_host_output=$(host "$1" 2>/dev/null)
	if echo -e "$raw_host_output" | grep -q "mail is handled"; then
		host_output=$(echo "$raw_host_output" | grep -B100 -A0 -m1 "mail is handled" | sed '$d')
	else
		host_output="$raw_host_output"
	fi
	ip=$(echo "$host_output" | grep -Eo "$ipv4v6regex")
	echo -e "$ip\n"
}

PrintErrorAndExit(){
	if [ "$JSON_OUTPUT" = true ]; then
		# json output
		status_json_output="fail"
		reason_json_output="${1//\"/\\\"}"
		json_resultcount=0
		PrintJsonOutput
	elif [ "$IS_ASN_CHILD" = true ]; then
		echo -e "\n${redbg}${1}${default}\n" # get the error in the html report
		tput sgr0
	else
		# normal output
		echo -e "\n${redbg}${1}${default}" >&2
		tput sgr0
	fi
	exit 1
}

PrintUsage(){
	# if an argument is passed, it will be displayed on stderr and the script will exit with error
	script_name=$(basename "$0")
	JSON_OUTPUT=false
	BoxHeader "ASN / RPKI validity / BGP stats / IPv4v6 / Prefix / ASPath / Organization / IP reputation lookup tool" >&2
	echo -e "\nVERSION:\n\n  ${ASN_VERSION}" \
			"\n\nUSAGE:\n\n  $script_name [${green}OPTIONS${default}] [${blue}TARGET${default}]" \
			"\n  $script_name [${red}-v${default}] ${red}-l${default} [${red}SERVER OPTIONS${default}]" \
			"\n\nOPTIONS:" \
			"\n\n  ${green}-t    (enable trace)\n\t${default}Enable AS path trace to the ${blue}TARGET${default} (this is the default behavior)" \
			"\n\n  ${green}-n    (no trace|no additional INETNUM lookups)\n\t${default}Disable tracing the AS path to the ${blue}TARGET${default} (for IP targets) or" \
			"\n\tDisable additional (unannounced / announced by other AS) INETNUM lookups for the ${blue}TARGET${default} (for AS targets)" \
			"\n\n  ${green}-d    (detailed)\n\t${default}Output detailed hop info during the AS path trace to the ${blue}TARGET${default}" \
			"\n\tThis option also enables RPKI validation/BGP hijacking detection for every hop" \
			"\n\n  ${green}-a    (ASN Suggest)\n\t${default}Lookup AS names and numbers matching ${blue}TARGET${default}" \
			"\n\n  ${green}-u    (Transit/Upstream lookup)\n\t${default}Inspect BGP updates and ASPATHs for the ${blue}TARGET${default} address/prefix and identify possible transit/upstream autonomous systems" \
			"\n\n  ${green}-c    (Country CIDR)\n\t${default}Lookup all IPv4/v6 CIDR blocks allocated to the ${blue}TARGET${default} country" \
			"\n\n  ${green}-g    (Bulk Geolocate)\n\t${default}Geolocate all IPv4/v6 addresses passed as ${blue}TARGET${default}" \
			"\n\tThis mode supports multiple targets, stdin input and IP extraction from input, e.g." \
			"\n\t'asn -g < /var/log/apache2/error.log' or 'echo 1.1.1.1 2.2.2.2 | asn -g'" \
			"\n\n  ${green}-s    (Shodan scan)\n\t${default}Query Shodan's InternetDB for CVE/CPE/Tags/Ports/Hostnames data about ${blue}TARGET${default}" \
			"\n\tThis mode supports multiple targets and stdin input, e.g." \
			"\n\t'asn -s < iplist' or 'echo 1.1.1.0/24 google.com | asn -s'" \
			"\n\n  ${green}-o    (organization search)\n\t${default}Force ${blue}TARGET${default} to be treated as an Organization Name" \
			"\n\n  ${green}-m    (monochrome output)\n\t${default}Disable colored output" \
			"\n\n  ${green}-v    (verbose)\n\t${default}Enable debug messages (URLs being queried and variable names being assigned)${default}" \
			"\n\n  ${green}-j    (compact JSON output)\n\t${default}Set output to compact JSON mode (ideal for machine parsing)" \
			"\n\n  ${green}-J    (pretty-printed JSON output)\n\t${default}Set output to pretty-printed JSON mode" \
			"\n\n  ${green}-h    (help)\n\t${default}Show this help screen" \
			"\n\n  ${red}-l    (lookup server)\n\t${default}Launch the script in server mode. See ${red}SERVER OPTIONS${default} below" \
			"\n\nTARGET:" \
			"\n\n  ${blue}<AS Number>${default}\n\tLookup matching ASN and BGP announcements/neighbours data." \
			"\n\t(Supports \"as123\" and \"123\" formats - case insensitive)" \
			"\n\n  ${blue}<IPv4/IPv6>${default}\n\tLookup matching route(4/6), IP reputation and ASN data" \
			"\n\n  ${blue}<Prefix>${default}\n\tLookup matching ASN data" \
			"\n\n  ${blue}<host.name.tld>${default}\n\tLookup matching IP, route and ASN data. Supports multiple IPs - e.g. DNS RR" \
			"\n\n  ${blue}<URL>${default}\n\tExtract hostname/IP from the URL and lookup relative data. Supports any protocol prefix, non-standard ports and prepended credentials" \
			"\n\n  ${blue}<Organization Name>${default}\n\tSearch by company name and lookup network ranges exported by (or related to) the company" \
			"\n\nSERVER OPTIONS:" \
			"\n\n  ${red}BIND_ADDRESS${default}\n\tIP address (v4/v6) to bind the listening server to (e.g. '$script_name -l 0.0.0.0')\n\tDefault value: ${red}${DEFAULT_SERVER_BINDADDR_v4} (IPv4) or ${DEFAULT_SERVER_BINDADDR_v6} (IPv6)${default}" \
			"\n\n  ${red}BIND_PORT${default}\n\tTCP Port to bind the listening server to (e.g. '$script_name -l 12345')\n\tDefault value: ${red}${DEFAULT_SERVER_BINDPORT}${default}" \
			"\n\n  ${red}BIND_ADDRESS${default} ${red}BIND_PORT${default}\n\tIP address and port to bind the listening server to (e.g. '$script_name -l ::1 12345')" \
			"\n\n  ${red}-v    (verbose)\n\t${default}Enable verbose output and debug messages in server mode${default}" \
			"\n\n  ${red}--allow host[,host,...]\n\t${default}Allow only given hosts to connect to the server${default}" \
			"\n\n  ${red}--allowfile file\n\t${default}A file of hosts allowed to connect to the server${default}" \
			"\n\n  ${red}--deny host[,host,...]\n\t${default}Deny given hosts from connecting to the server${default}" \
			"\n\n  ${red}--denyfile file\n\t${default}A file of hosts denied from connecting to the server${default}" \
			"\n\n  ${red}-m, --max-conns <n>\n\t${default}The maximum number of simultaneous connections accepted by the server. 100 is the default.${default}" \
			"\n\n\n  Note: Every option in server mode (after -l) is passed directly to the ncat listener." \
			"\n        Refer to ${blue}man ncat${default} for more details on the available commands." \
			"\n        Unless specified, the default IP:PORT values of ${DEFAULT_SERVER_BINDADDR_v4}:${DEFAULT_SERVER_BINDPORT} (for IPv4) or [${DEFAULT_SERVER_BINDADDR_v6}]:${DEFAULT_SERVER_BINDPORT} (for IPv6) will be used (e.g. 'asn -l')" \
			"\n\n  Example server usage:" \
			"\n\t${blue}asn -l${default}" \
			"\n\t  (starts server on default IP(v4/v6):PORT)\n" \
			"\n\t${blue}asn -l 0.0.0.0 --allow 192.168.0.0/24,192.168.1.0/24,192.168.2.245${default}" \
			"\n\t  (binds to all availables IPv4 interfaces on the default port, allowing only connections from the three specified subnets)\n" \
			"\n\t${blue}asn -l :: 2222 --allow 2001:DB8::/32${default}" \
			"\n\t  (binds to all availables IPv6 interfaces on port 2222, allowing only connections from the specified prefix)\n" \
			"\n\t${blue}asn -v -l 0.0.0.0 --allowfile \"~/goodips.txt\" -m 5${default}" \
			"\n\t  (verbose mode, bind to all IPv4 interfaces, use an allowfile with allowed addresses, accept a maximum of 5 concurrent connections)\n" \
			"\n  Bookmarklet configuration page:" \
			"\n\tplease visit ${blue}http://127.0.0.1:49200/asn_bookmarklet${default} and follow the instructions. More documentation is available on github (link below)." \
			"\n\n\nProject homepage: ${yellow}https://github.com/nitefood/asn${default}\n" >&2

	[[ -n "$1" ]] && PrintErrorAndExit "$1"
}

PwhoisLookup(){
	StatusbarMessage "Collecting pWhois data"
	pwhois_output=$(whois -h whois.pwhois.org "$1")
	StatusbarMessage
	if echo "$pwhois_output" | grep -vq "That IP address doesn't appear"; then
		# pwhois_asn=$(echo "$pwhois_output" | grep -E "^Origin-AS" | cut -d ':' -f 2 | sed 's/^ //')
		# pwhois_prefix=$(echo "$pwhois_output" | grep -E "^Prefix" | cut -d ':' -f 2 | sed 's/^ //')
		pwhois_asorg=$(echo "$pwhois_output" | grep -E "^AS-Org-Name" | cut -d ':' -f 2 | sed 's/^ //')
		# group all "Org-Name" fields on a single line
		pwhois_org=$(echo "$pwhois_output" | grep -E "^Org-Name" | cut -d ':' -f 2 | sed 's/^[ \t]*//g' | while read -r line; do echo -n "$line / "; done | sed 's/ \/ $//')
		pwhois_net=$(echo "$pwhois_output" | grep -E "^Net-Name" | cut -d ':' -f 2 | sed 's/^ //')
		# if pWhois' Net-Name=Org-Name, then it's more useful to use AS-Org-Name instead of Org-Name (unless AS-Org-Name is empty)
		if [ -n "$pwhois_asorg" ] && [ "$pwhois_net" = "$pwhois_org" ]; then
			pwhois_org="$pwhois_asorg"
		fi
		IPGeoRepLookup "$1"
		IPShodanLookup "$1"
		pwhois_geo="$ip_geo_data"
		if [ -z "$ip_geo_data" ]; then
			if echo "$pwhois_output" | grep -q -E "^Geo-"; then
				# use "Geo-" fields in pWhois output
				cityfield="Geo-City"
				regionfield="Geo-Region"
				ccfield="Geo-CC"
			else
				cityfield="City"
				regionfield="Region"
				ccfield="Country-Code"
			fi
			pwhois_city=$(echo "$pwhois_output" | grep -m1 -E "^${cityfield}" | cut -d ':' -f 2 | sed 's/^ //')
			pwhois_region=$(echo "$pwhois_output" | grep -m1 -E "^${regionfield}" | cut -d ':' -f 2 | sed 's/^ //')
			pwhois_cc=$(echo "$pwhois_output" | grep -m1 -E "^${ccfield}" | cut -d ':' -f 2 | sed 's/^ //')
			flag_icon_cc=$(tr '[:upper:]' '[:lower:]' <<<"$pwhois_cc")
			if [ "$pwhois_city" = "NULL" ] || [ "$pwhois_region" = "NULL" ]; then
				pwhois_geo="$pwhois_cc"
			else
				pwhois_geo="$pwhois_city, $pwhois_region ($pwhois_cc)"
			fi
		fi
	else
		pwhois_output="";
	fi
}

RdnsLookup(){
	# reverse DNS (PTR) lookup.
	# get first lookup result only (in case of multiple PTR records) and remove trailing dot and CR (Cygwin) from hostname
	rdns=$(host "$1" | awk 'NR==1{sub(/\.\r?$/, "", $NF); print $NF}')
	if echo "$rdns" | grep -E -q "NXDOMAIN|SERVFAIL|REFUSED|^record$"; then rdns=""; fi
	echo "$rdns"
}

AbuseLookupForPrefix(){
	# $1="whois data", $2=prefix
	if [ -n "$mtr_output" ] && [ "$DETAILED_TRACE" = false ]; then
		# skip abuse lookup for individual trace hops in non-detailed mode
		return
	fi
	whoisdata="$1"
	prefix="$2"
	abuselist=""
	for abusecontact in $(echo -e "$whoisdata" | grep -E "^OrgAbuseEmail:|^abuse-c:|^% Abuse|^abuse-mailbox:" | awk '{print $NF}' | tr -d \'); do
		if ! grep -q '@' <<<"$abusecontact"; then
			resolvedabuse=$(docurl -m5 -s "https://stat.ripe.net/data/abuse-contact-finder/data.json?resource=$2&sourceapp=nitefood-asn" | jq -r 'select (.data.abuse_contacts != null) | .data.abuse_contacts[]')
			[[ -n "$resolvedabuse" ]] && abusecontact="$resolvedabuse"

		fi
		[[ -n "$abuselist" ]] && abuselist+="\n"
		abuselist+="$abusecontact"
	done

	if [ "$JSON_OUTPUT" = true ]; then
		# json output
		if [ -n "$abuselist" ]; then
			echo -e "$abuselist" | jq -cM --slurp --raw-input 'split("\n") | map(select(length > 0)) | unique'
		fi
	else
		# normal output
		if [ -n "$abuselist" ]; then
			# use jq to join contacts together and separate them with the " / " multi-character delimiter, while getting rid of spurious newlines
			echo -e "$abuselist" | jq -r --slurp --raw-input 'split("\n") | map(select(length > 0)) | unique | join(" / ")'
		else
			echo "-"
		fi
	fi
}

HopPrint(){
	StatusbarMessage
	# shellcheck disable=SC2124
	output="$@"
	# create hyperlinks if running in server mode
	if [ "$IS_ASN_CHILD" = true ]; then
		[[ -z "$ixp_tag" ]] && htmlcolor="$htmlwhite" || htmlcolor="$htmlblue"
		# extract and trim duplicate IPs from the trace output line
		found_ips=$(grep -Eo "${ipv4v6regex}" <<<"$output" | sort -u)
		if [ -n "$found_ips" ]; then
			for ip in $found_ips; do
				# replace only the last IP in the trace output, so to handle special cases
				# where the trace hop PTR contains the full dotted IP, ex:
				# 1.2.3.4.domain.name (1.2.3.4) -> 1.2.3.4.domain.name (<href to 1.2.3.4>)
				output=$(sed "s/\(.*\)$ip/\1<a href=\"\/asn_lookup\&$ip\" class=\"hidden_underline\" style=\"color: $htmlcolor;\">$ip<\/a>/" <<<"$output")
			done
		fi
	fi
	echo -e "$output"
	StatusbarMessage "Analyzing collected trace output to ${bluebg}${host_to_trace}${lightgreybg}"
}

TraceASPath(){
	starttime=$(date +%s)
	host_to_trace="$1"
	border_color="$lightblue"
	# attepmt to be as responsive as possible
	# ideal output width : 150 (size of headers in normal traces)
	# ideal border width : 100 (used in detailed traces only)
	if [ "$terminal_width" -ge 153 ]; then
		output_width=150
		border_width=100
	elif [ "$terminal_width" -ge 103 ]; then
		output_width=$((terminal_width-3))
		border_width=100
	else
		output_width=$((terminal_width-3))
		border_width=$((terminal_width-3))
	fi

	WhatIsMyIP
	if [ "$DETAILED_TRACE" = true ]; then
		headermsg="Detailed trace to $userinput"
	else
		headermsg="Trace to $userinput"
	fi
	BoxHeader "$headermsg"
	# check if we're trying to trace an IPv6 from an IPv4-only box
	echo "$host_to_trace" | grep -q ':' && is_ipv6=true || is_ipv6=false
	if [ "$is_ipv6" = true ] && [ "$HAVE_IPV6" = false ]; then
		PrintErrorAndExit "Error: cannot trace an IPv6 from this IPv4-only host!"
	fi
	echo ""
	StatusbarMessage "Collecting trace data to ${bluebg}${host_to_trace}${lightgreybg}"

	# start the mtr trace
	DebugPrint "${yellow}mtr -> $host_to_trace ($MTR_ROUNDS rounds)${default}"
	mtr_output=$(mtr -C -n -c"$MTR_ROUNDS" "$host_to_trace" | tail -n +2)
	declare -a tracehops_array
	declare -a aspath_array
	# initialize the aspath array with our source AS
	if [ "$HAVE_IPV6" = true ]; then
		found_asn=$(docurl -s "https://stat.ripe.net/data/whois/data.json?resource=$local_wanip&sourceapp=nitefood-asn" | jq -r '.data.irr_records[0] | map(select(.key | match ("origin"))) | .[].value')
		WhoisASN "$found_asn"
	else
		LookupASNAndRouteFromIP "$local_wanip"
	fi
	if [ -z "$found_asn" ]; then
		found_asn="XXX"
		found_asname="(Unknown)"
	fi
	if [ "$IS_ASN_CHILD" = true ]; then
		aspatharray_asnvalue="<a href=\"/asn_lookup&AS$found_asn\" style=\"color: $htmlred; display:inline-block; width: 4em;\">$found_asn</a>"
	else
		aspatharray_asnvalue="$found_asn"
	fi
	# Retrieve local AS CAIDA rank
	GetCAIDARank "$found_asn"
	if [ -n "$caida_asrank_text" ]; then
		aspath_entry=$(printf "${red}%-6s ${green}%s${default}${dim} •%s${dim}${default}" "$aspatharray_asnvalue" "$(echo "$found_asname" | cut -d ',' -f 1)" "$caida_asrank_text")
	else
		aspath_entry=$(printf "${red}%-6s ${green}%s${default}" "$aspatharray_asnvalue" "$(echo "$found_asname" | cut -d ',' -f 1)")
	fi
	aspath_array+=("$aspath_entry")

	# mtr finished, analyze and output results
	# print trace headers (only non-detailed trace)
	if [ "$DETAILED_TRACE" = false ]; then
		HopPrint "$(printf "${lightgreybg}%4s %-$((output_width-61))s %7s %13s     %s                ${default}" "Hop" "IP Address" "Loss%" "Ping avg" "AS Information")"
	fi
	LAST_HOP=false
	ROUTING_LOOP=false

	# parse mtr output (csv)
	hop_num=0
	while true; do
		((hop_num++))
		IFS=',' read -ra cur_hop_data <<< "$(echo "$mtr_output" | head -n "$hop_num" | tail -n 1)"
		mtr_hopnum=${cur_hop_data[4]}
		[[ "$hop_num" -gt "$mtr_hopnum" ]] && break # we're past the last trace hop, quit the loop
		hop_ip=${cur_hop_data[5]}
		hop_loss=${cur_hop_data[6]%.*}
		hop_ping=$(echo "${cur_hop_data[10]}" | awk '{ printf ("%.1f\n", $1) }')
		if [ "$hop_loss" -ne 0 ]; then
			# color packet loss yellow if between 1% and 50%, or red if > 50%
			[[ "$hop_loss" -le 50 ]] && loss_color="$lightyellow" || loss_color="$lightred"
			if [ "$DETAILED_TRACE" = false ]; then
				hop_loss=$(printf "${loss_color}%5s" "$hop_loss") # packet loss position in normal path trace (spacing to fit the column alignment)
			else
				hop_loss="${loss_color}${hop_loss}" # packet loss position in detailed path trace (no spacing)
			fi
		fi
		tracehops_array["$hop_num"]="$hop_ip"
		ixp_tag=""
		hop_asn=""
		if [ "$hop_ip" = "???" ]; then
			# print no reply hop info
			if [ "$DETAILED_TRACE" = true ]; then
				trailing_line=$(printf '%.0s═' $(seq $((border_width-9-${#hop_ip}))) )
				hop_output="$(printf "${border_color}╔═[${default}%3s. %s ${border_color}]%s╗${default}\n" "$hop_num" "$hop_ip" "$trailing_line")"
				hop_output+="\n        ├${bluebg}RTT${default} ${white}* (No reply)${default}\n"
				hop_output+="        └${bluebg}LOS${default} ${hop_loss}%${default} packet loss\n"
			else
				hop_output="$(printf "%3s. %-$((output_width-60))s %6s${default} %13s   %s" "$hop_num" "$hop_ip" "$hop_loss%" "*" "${white}(No reply)${default}")"
			fi
			HopPrint "${hop_output}"
			continue # jump to the next hop
		fi

		# do a reverse DNS lookup for the IP
		hostname=$(RdnsLookup "$hop_ip")

		# check for routing loops, if so fail immediately
		if [ "$hop_num" -ge 2 ]; then
			prev_hop=${tracehops_array[$(( hop_num-1 ))]}
			# Check disabled to avoid detecting routing loops in rare cases where the same hop appears twice in a row during the trace
			# if [ "$hop_ip" = "$prev_hop" ]; then
			# 	ROUTING_LOOP=true
			# 	break
			# fi
		fi
		if [ "$hop_num" -ge 4 ]; then
			# detect routing loops
			two_hops_ago=${tracehops_array[$(( hop_num-2 ))]}
			three_hops_ago=${tracehops_array[$(( hop_num-3 ))]}
			if [ "$hop_ip" = "$two_hops_ago" ] && [ "$prev_hop" = "$three_hops_ago" ]; then
				ROUTING_LOOP=true
				break
			fi
		fi
		# AS DATA lookup
		# check if it's the last hop
		[[ "$hop_ip" = "$host_to_trace" ]] && LAST_HOP=true
		LookupASNAndRouteFromIP "$hop_ip"
		# check if IP is a bogon
		if [ "$IS_BOGON" = true ]; then
			asn_data="$bogon_tag"
			pwhois_output=""
		else
			# Hop IP is not a bogon address. Proceed with lookup of hop data
			if [ "$UNANNOUNCED_PREFIX" = true ]; then
				# No data in the Team Cymru DB. Check to see if the ip is assigned to an IXP, or fall back to generic whois.
				WhoisIP "$hop_ip" >/dev/null # don't display this, we're being parsed off-screen
				hop_asn="${red}N/A (address not announced)${default}"
				hop_org="$pwhois_org"
				hop_net="$pwhois_net"
				[[ -n "$found_route" ]] && hop_net+=" ($found_route)"
				hop_typ="$ip_type_data"
				hop_cpe="$ip_shodan_cpe_data"
				hop_ports="$ip_shodan_ports_data"
				hop_tags="$ip_shodan_tags_data"
				hop_cve="$ip_shodan_cve_data"
				hop_geo="$pwhois_geo"
				hop_rep="$ip_rep_data"
				if [ -n "$ixp_data" ]; then
					# this hop is an IXP
					ixp_tag="${bluebg} IXP ${default}"
					asn_data="${ixp_tag} ${blue}${ixp_data}${default}"
					hop_org="${ixp_tag} ${blue}${ixp_data}${default}"
					aspath_entry=$(printf "%-6s  ${blue}%s${default}" "$ixp_tag" "$ixp_data")
					aspath_array+=("$aspath_entry")
				else
					# no data found and not an IXP hop, try retrieving relevant info from a generic whois lookup
					hop_whois_data=$(echo -e "$full_whois_data" | grep -i -m2 -E "^netname:|^orgname:|^org-name:|^descr:" | cut -d ':' -f 2 | sed 's/^[ \t]*//' | while read -r line; do echo -n "$line / "; done | sed 's/ \/ $//')
					if [ -z "$hop_whois_data" ]; then
						asn_data="${yellow}(No data)${default}"
					else
						asn_data="${yellow}(${hop_whois_data})${default}"
					fi
				fi
			else
				# $hop_ip belongs to an announced prefix
				if [ "$IS_ASN_CHILD" = true ]; then
					asn_data="${red}[<a href=\"/asn_lookup&AS$found_asn\" class=\"hidden_underline\" style=\"color: $htmlred;\">AS$found_asn</a>] ${green}$found_asname${default}"
					aspatharray_asnvalue="<a href=\"/asn_lookup&AS$found_asn\" style=\"color: $htmlred; display:inline-block; width: 4em;\">$found_asn</a>"
				else
					asn_data="${red}[AS$found_asn] ${green}$found_asname${default}"
					aspatharray_asnvalue="$found_asn"
				fi
				# Retrieve AS CAIDA rank for this hop
				GetCAIDARank "$found_asn"
				if [ -n "$caida_asrank_text" ]; then
					aspath_entry=$(printf "${red}%-6s ${green}%s${default}${dim} •%s${dim}${default}" "$aspatharray_asnvalue" "$(echo "$found_asname" | cut -d ',' -f 1)" "$caida_asrank_text")
				else
					aspath_entry=$(printf "${red}%-6s ${green}%s${default}" "$aspatharray_asnvalue" "$(echo "$found_asname" | cut -d ',' -f 1)")
				fi
				# avoid adding the same AS multiple times in a row in the summary path
				if [[ "${aspath_array[-1]}" != "$aspath_entry" ]]; then
					aspath_array+=("$aspath_entry")
				fi
			fi
			if [ "$DETAILED_TRACE" = true ] && [ "$UNANNOUNCED_PREFIX" = false ]; then
				hop_asn="$found_asn"
				hop_prefix="$found_route"

				# run a pWhois lookup if the hop is within an announced prefix
				PwhoisLookup "$hop_ip"

				# in the event where Cymru has data, but pWhois doesn't, run a WhoisIP to fetch generic whois info
				# specifying the "generic_whois_lookup_only" parameter in order not to run pWhois/IXP lookups again
				[[ -z "$pwhois_output" ]] && WhoisIP "$hop_ip" "generic_whois_lookup_only" >/dev/null # don't display this, we're being parsed off-screen
				hop_org="$pwhois_org"
				hop_net="$pwhois_net"
				hop_typ="$ip_type_data"
				hop_cpe="$ip_shodan_cpe_data"
				hop_ports="$ip_shodan_ports_data"
				hop_tags="$ip_shodan_tags_data"
				hop_cve="$ip_shodan_cve_data"
				hop_geo="$pwhois_geo"
				hop_rep="$ip_rep_data"
			fi
		fi

		# DNS data (only used if a hostname was resolved)
		if [ -n "$hostname" ] && [ ! "$hostname" = "-" ]; then
			hop_ip="$hostname ($hop_ip)"
		fi
		# IXP coloring
		[[ -z "$ixp_tag" ]] && hop_ip="${white}${hop_ip}${default}" || hop_ip="${blue}${hop_ip}${default}"

		# print trace hop info
		if [ "$DETAILED_TRACE" = false ]; then
			hop_output="$(printf "%3s. %-$((output_width-45))s %6s${default} %10s ms   %s" "$hop_num" "${hop_ip}" "$hop_loss%" "${hop_ping}" "$asn_data")"
		else
			trailing_line=$(printf '%.0s═' $(seq $((border_width+6-${#hop_ip}))) )
			hop_output="$(printf "${border_color}╔═[${default}%3s. %s ${border_color}]%s╗${default}\n" "$hop_num" "${hop_ip}" "$trailing_line")"
			hop_output+="\n        ├${bluebg}RTT${default} ${white}${hop_ping} ms${default}\n"
			hop_output+="        ├${bluebg}LOS${default} ${hop_loss}%${default} packet loss${default}"
			# only add ASN data when not an IXP, otherwise we'll have duplicate data when ORG gets printed later
			if [ -z "$ixp_tag" ]; then
				# if it's a bogon address it's going to be the last branch of the displayed tree
				if [ "$IS_BOGON" = true ]; then
					hop_output+="\n        └${bluebg}TYP${default} $asn_data${default}"
				else
					hop_output+="\n        ├${bluebg}ASN${default} $asn_data${default}"
				fi
			fi
		fi
		HopPrint "$hop_output"

		if [ "$DETAILED_TRACE" = true ] && [ -n "$hop_asn" ]; then
			if [ -n "$found_asname" ]; then
				# only run RPKI lookups if the prefix is announced
				RPKILookup "$found_asn" "$hop_prefix"
				if [ "$INVALID_ROA" = true ]; then
					# notify user of possible BGP hijack/route leak
					aspath_array[-1]+=" ${redbg} ─> WARNING: POSSIBLE ROUTE LEAK / BGP HIJACK ${default}"
				fi
			else
				rpki_output="${red}N/A (hop address not announced)${default}"
			fi
			# compose hop detail output
			# 1. hop ASN, ORG, NET, ROA
			hop_details=""
			[[ "$DETAILED_TRACE" = false ]] && hop_details="       ├${bluebg}ASN${default} ${red}${hop_asn}${default}\n"
			[[ "$ixp_tag" = "" ]] && hop_details+="        ├${bluebg}RNK${default} ${caida_asrank_recap}${default}\n"
			hop_details+="        ├${bluebg}ORG${default} ${green}${hop_org}${default}\n"
			hop_details+="        ├${bluebg}NET${default} ${yellow}${hop_net}${default}\n"
			hop_details+="        ├${bluebg}ROA${default} ${rpki_output}\n"
			# 2. hop TYP (optional, only if hop is a particular IP type (anycast/hosting/etc))
			[[ -n "$hop_typ" ]] && hop_details+="        ├${bluebg}TYP${default}${hop_typ}${default}\n"
			# 3. hop CPE, PORTS, TAGS, CVE
			[[ -n "$hop_cpe" ]] && hop_details+="        ├${bluebg}CPE${default}${hop_cpe}${default}\n"
			[[ -n "$hop_ports" ]] && hop_details+="        ├${bluebg}POR${default}${hop_ports}${default}\n"
			[[ -n "$hop_tags" ]] && hop_details+="        ├${bluebg}TAG${default}${hop_tags}${default}\n"
			[[ -n "$hop_cve" ]] && hop_details+="        ├${bluebg}CVE${default}${hop_cve}${default}\n"
			# 4. hop GEO, REP
			hop_details+="        ├${bluebg}GEO${default} ${magenta}${hop_geo}${default}\n"
			hop_details+="        └${bluebg}REP${default} ${hop_rep}${default}"
			[[ "$DETAILED_TRACE" = false ]] && hop_details+="\n"
			# display hop details on screen
			HopPrint "$hop_details"
			[[ "$DETAILED_TRACE" = true ]] && HopPrint "\n"
		elif [ "$DETAILED_TRACE" = true ]; then
			# PWHOIS lookups ON, but no valid hop data (e.g. no-reply hop). Just add a newline
			[[ "$DETAILED_TRACE" = true ]] && HopPrint "\n"
		fi
		[[ "$LAST_HOP" = true ]] && break
	done
	# mtr output parsing complete
	if [ "$LAST_HOP" = false ]; then
		# last hop wasn't our target IP. Add a missing last hop to the trace.
		mtr_end_msg="${redbg} no route to host"
		[[ "$ROUTING_LOOP" = true ]] && mtr_end_msg+=" (routing loop detected)"
		mtr_end_msg+=" ${default}"
		# print hop info with final error message
		if [ "$DETAILED_TRACE" = false ]; then
			HopPrint "$(printf "%3s. %-$((output_width-40))s ${lightred}%11s%%${default} %13s   %s" "$hop_num" "$mtr_end_msg" "100" "*" "${white}(No reply)${default}")"
		else
			upper_border="${border_color}╔$(printf '%.0s═' $(seq "$border_width"))╗${default}"
			lower_border="${border_color}╚$(printf '%.0s═' $(seq "$border_width"))╝${default}"
			HopPrint "${upper_border}\n  ${mtr_end_msg}\n${lower_border}"
		fi
		aspath_array+=("${mtr_end_msg}${default}")
	fi

	endtime=$(date +%s)
	runtime=$((endtime-starttime))
	StatusbarMessage
	if [ "$IS_ASN_CHILD" = true ]; then
		# date and time is already displayed elsewhere in server mode
		echo -e "\nTrace completed in $runtime seconds.\n"
	else
		tracetime=$(date +'%F %T %Z')
		echo -e "\nTrace completed in $runtime seconds on $tracetime\n"
	fi

	BoxHeader "AS path to $userinput"
	echo -en "\n  "
	for as in "${aspath_array[@]}"; do
		if [ "$as" = "${aspath_array[0]}" ]; then
			echo -en "${as} ${yellowbg} Local AS ${default}"
		else
			echo -en "${as}${default}"
		fi
		if [ "$as" != "${aspath_array[-1]}" ]; then
			echo -en "\n ╭╯\n ╰"
		fi
	done
	echo -e "\n"
}

SearchByOrg(){
	unset orgs
	declare -a orgs
	echo ""
	if [ "$ORG_FILTER" = false ]; then
		StatusbarMessage "Searching for organizations matching ${bluebg}$1${lightgreybg}"
		full_org_search_data=$(whois -h whois.pwhois.org "registry org-name=$1")
		original_organizations=$(echo -e "$full_org_search_data" | grep -E "^Org-Name:" | cut -d ':' -f 2- | sed 's/^ //g' | sort -uf)
		total_orgsearch_results=$(echo -e "$original_organizations" | wc -l)
		organizations="$original_organizations"
	else
		# user chose to apply a search filter to a previous query
		if [ ${#orgfilters_array[@]} -eq 0 ] && [ ${#excl_orgfilters_array[@]} -eq 0 ]; then
			# user deleted all search filters. Revert to original query result
			organizations="$original_organizations"
			ORG_FILTER=false
		else
			StatusbarMessage "Applying filters"
			filtered_org="$original_organizations"
			# parse all inclusion filters
			for filter in "${orgfilters_array[@]}"; do
				apply_filter=$(echo -e "$filtered_org" | grep -i -- "$filter")
				if [ -z "$apply_filter" ]; then
					StatusbarMessage
					echo -en "${yellow}Warning: No results found for ${bluebg}${filter}${default}"
					sleep 2
					# remove last filter term
					unset 'orgfilters_array[${#orgfilters_array[@]}-1]'
				else
					filtered_org="$apply_filter"
				fi
			done
			# parse all exclusion filters
			for filter in "${excl_orgfilters_array[@]}"; do
				apply_filter=$(echo -e "$filtered_org" | grep -i -v -- "$filter")
				if [ -z "$apply_filter" ]; then
					StatusbarMessage
					echo -en "${yellow}Warning: No more results found if excluding ${bluebg}${filter}${default}"
					sleep 2
					# remove last filter term
					unset 'excl_orgfilters_array[${#excl_orgfilters_array[@]}-1]'
				else
					filtered_org="$apply_filter"
				fi
			done
			# have we removed all filters (because of no matches)? go back to unfiltered results
			if [ ${#orgfilters_array[@]} -eq 0 ] && [ ${#excl_orgfilters_array[@]} -eq 0 ]; then
				ORG_FILTER=false
				echo ""
			fi
			organizations="$filtered_org"
		fi
	fi
	for orgname in $organizations; do
		orgs+=("$orgname")
	done
	StatusbarMessage

	if [ ${#orgs[@]} -eq 0 ]; then
		# company search yielded no results
		PrintErrorAndExit "Error: no organizations found"
	fi

	# Menu showing loop
	while true; do
		ShowMenu
		searchresults=""
		[[ "$LOOKUP_ALL_RESULTS" == true ]] && orgs_to_lookup=("${orgs[@]}") || orgs_to_lookup=("$org")
		for org in "${orgs_to_lookup[@]}"; do
			orgids=$(echo -e "$full_org_search_data" | grep -i -E -B1 "Org-Name: $org$" | grep "Org-ID" | cut -d ':' -f 2- | sed 's/^ //g')
			NO_ERROR_ON_INTERRUPT=true
			for ipversion in 4 6; do
				NO_RESULTS=true
				searchresults+=$(BoxHeader "IPv${ipversion} networks for organization \"${org}\"")
				# iterate over Org-IDs related to the company (in case of multiple Org-IDs for a single Org-Name)
				for orgid in $orgids; do
					StatusbarMessage "Looking up IPv${ipversion} networks for organization ${bluebg}$org${lightgreybg} (Org-ID: ${bluebg}${orgid}${lightgreybg})"
					netblocks_output=""
					if [ "$ipversion" = "4" ]; then
						# Parse IPv4 NETBLOCKS
						netblocks=$(whois -h whois.pwhois.org "netblock org-id=${orgid}" | grep -E "^\*>")
						netblocks_header="            IPv4 NET RANGE                | INFO"
						for netblock in $netblocks; do
							prefix=$(echo -e "$netblock" | cut -d '>' -f 2 | cut -d '|' -f 1)
							netname=$(echo -e "$netblock" | cut -d '>' -f 2 | cut -d '|' -f 2 | tr -d ' ')
							netblock_type=$(echo -e "$netblock" | cut -d '>' -f 2 | cut -d '|' -f 3 | tr -d ' ')
							if [ "$netblock_type" = "unknown" ]; then
								nettype=""
							else
								nettype=" (${yellow}$netblock_type${default})"
							fi
							regdate=$(echo -e "$netblock" | cut -d '>' -f 2 | cut -d '|' -f 4 | tr -d ' ')
							if [ "$HAVE_IPCALC" = true ]; then
								# deaggregate IPv4 netblocks into CIDR prefixes for readability
								prefix_spacing=19
								trimmed_prefix=$(echo "$prefix" | tr -d ' ')
								prefix=$(IpcalcDeaggregate "$trimmed_prefix")
							else
								# no ipcalc, use direct pWhois output
								prefix_spacing=41
							fi
							netblocks_output+=$(printf "\n${blue}%${prefix_spacing}s${default} | ${green}%-45s${default} - Registered: ${magenta}%s${default}%s" "$prefix" "$netname" "$regdate" "$nettype")
						done
						[[ "$HAVE_IPCALC" = true ]] && netblocks_header="    IPv4 PREFIX     |       INFO"
					else
						# Parse IPv6 NETBLOCKS
						netblocks=$(whois -h whois.pwhois.org "netblock6 org-id=${orgid}" | grep -E "^Net-(Range|Name|Handle|Type)|^Register-Date" |\
							cut -d ':' -f 2- |\
							sed 's/^ //g' |\
							awk '{if (NR%5) {ORS=""} else {ORS="\n"}{print $0"|"}}') # cheers https://stackoverflow.com/a/35315421/5377165
						netblocks_header="                       IPv6 NET RANGE                         | INFO"
						for netblock in $netblocks; do
							prefix=$(echo -e "$netblock" | cut -d '|' -f 1)
							netname=$(echo -e "$netblock" | cut -d '|' -f 2)
							nethandle=$(echo -e "$netblock" | cut -d '|' -f 3)
							netname+=" (${nethandle})"
							netblock_type=$(echo -e "$netblock" | cut -d '|' -f 4)
							if [ "$netblock_type" = "unknown" ]; then
								nettype=""
							else
								nettype=" (${yellow}$netblock_type${default})"
							fi
							regdate=$(echo -e "$netblock" | cut -d '|' -f 5)
							prefix_spacing=61
							netblocks_output+=$(printf "\n${blue}%${prefix_spacing}s${default} | ${green}%-45s${default} - Registered: ${magenta}%s${default}%s" "$prefix" "$netname" "$regdate" "$nettype")
						done
					fi
					if [ -n "$netblocks_output" ]; then
						# Print out netblocks
						NO_RESULTS=false
						searchresults+=$(echo -e "\n${red}Org-ID: ${magenta}${orgid}${red}${default}\n${netblocks_header}${netblocks_output}")
						searchresults+="\n"
					fi
				done
				[[ "$NO_RESULTS" = true ]] && searchresults+="\n\t${red}No results found${default}\n"
			done
		done
		NO_ERROR_ON_INTERRUPT=false
		StatusbarMessage
		echo -e "$searchresults\n${yellow}────────────────────────────────────────────────────${default}"
		# let the user choose if they want to run a quick IP lookup
		while true; do
			echo -e "\n- Enter any ${blue}IP/Prefix${default} to look it up or"
			echo -e "- Press ${yellow}ENTER${default} to return to the menu:\n"
			echo -n ">> "
			read -r choice
			# check if it's an IPv4/IPv6
			if [ -n "${choice}" ]; then
				input=$(echo "$choice" | sed 's/\/.*//g' | grep -Eo "$ipv4v6regex")
				if [ -n "$input" ]; then
					# valid IP
					echo ""
					StatusbarMessage "Looking up data for ${bluebg}${input}${lightgreybg}"
					LookupASNAndRouteFromIP "$input"
					(( longest=${#input}+1 ))
					WhoisIP "$input"
					PrintReputationAndShodanData "$input"
					StatusbarMessage
					continue
				else
					continue
				fi
			else
				# user pressed ENTER, go back to main organizations menu
				clear
				break
			fi
		done
	done
}

ShowMenu(){ # show selection menu for search-by-company results
	clear
	BoxHeader "Organizations matching \"$userinput\""
	if [ "$ORG_FILTER" = true ]; then
		num_inclusion_filters="${#orgfilters_array[@]}"
		num_exclusion_filters="${#excl_orgfilters_array[@]}"
		num_filters=$(( num_inclusion_filters+num_exclusion_filters ))
		[[ $num_filters = 1 ]] && s="" || s="s"
		ACTIVE_FILTERS_STRING=$'\n'"${bluebg}${black}${num_filters} Active filter${s}:${default}"

		# recap inclusion filters
		for filter in "${orgfilters_array[@]}"; do
			ACTIVE_FILTERS_STRING+=" ${lightgreybg}${filter}${default}"
		done

		# recap exclusion filters
		for filter in "${excl_orgfilters_array[@]}"; do
			ACTIVE_FILTERS_STRING+=" ${lightgreybg}${red}-${filter}${default}"
		done

		ACTIVE_FILTERS_STRING+=$'\n'
	else
		ACTIVE_FILTERS_STRING=""
	fi
	if [ "$HAVE_IPCALC" = true ]; then
		IPCALC_WARNING=""
	else
		IPCALC_WARNING=$'\n'"${yellow}Warning: program ${red}ipcalc${yellow} not found."$'\n'"Install it to enable netblock->CIDR"$'\n'"prefix aggregation.${default}"$'\n'
	fi
	PS3="${yellow}────────────────────────────────────────────────────${default}
$ACTIVE_FILTERS_STRING
${yellow}${#orgs[@]} of $total_orgsearch_results total results shown${default}

Choose an organization or enter:
- <${green}text${default}> to FILTER FOR A STRING
- <${blue}-${default}> to EXCLUDE A STRING
- <${blue}x${default}> to REMOVE ALL FILTERS
- <${blue}a${default}> to LOOKUP ALL RESULTS (max 10)
- <${blue}q${default}> to QUIT
$IPCALC_WARNING
>> "
	echo -e "${yellow}────────────────────────────────────────────────────${green}"
	COLUMNS=1
	set -o posix
	select choice in "${orgs[@]}"; do
		for org in "${orgs[@]}"; do
			if [[ "$org" = "$choice" ]]; then
				LOOKUP_ALL_RESULTS=false
				break 2
			fi
		done
		case "$REPLY" in
			"q"|"Q")
				echo ""
				exit 0
			;;
			"-")
				# add an exclusion filter
				echo -n "Enter a string to ${red}exclude${default}: "
				read -r exclusion_string
				excl_orgfilters_array+=("$exclusion_string")
				ORG_FILTER=true
				SearchByOrg
			;;
			"x"|"X")
				# reset filters
				if [ "$ORG_FILTER" = true ]; then
					unset orgfilters_array
					unset excl_orgfilters_array
					declare -a orgfilters_array
					declare -a excl_orgfilters_array
					SearchByOrg
				fi
			;;
			"a"|"A")
				# lookup all results
				if [ "${#orgs[@]}" -gt 10 ]; then
					echo -en "\n${redbg}Too many results! Please add some filters!${default}\n"
					sleep 2
					continue
				fi
				LOOKUP_ALL_RESULTS=true
				break
			;;
			*)
				# apply filter to the results
				orgfilters_array+=("$REPLY")
				ORG_FILTER=true
				SearchByOrg
			;;
		esac
	done
	set +o posix
	echo ""
}

PrintReputationAndShodanData(){
	# We already collected reputation and Shodan data since we called IPGeoRepLookup() and IPShodanLookup() previously
	if [ "$JSON_OUTPUT" = true ]; then
		# JSON output
		final_json_output+=",\"reputation\":{"
		[[ -n "$json_rep" ]] && final_json_output+="\"status\":\"$json_rep\""
		[[ -n "$json_iqs_threat_score" ]] && final_json_output+="$json_iqs_threat_score"
		[[ "$gn_noisy" = "true" ]] && final_json_output+=",\"is_noisy\":$gn_noisy"
		[[ -n "$gn_json_is_knowngood" ]] && final_json_output+=",\"is_known_good\":$gn_json_is_knowngood"
		[[ -n "$gn_json_is_knownbad" ]] && final_json_output+=",\"is_known_bad\":$gn_json_is_knownbad"
		[[ -n "$gn_json_aka" ]] && final_json_output+=",\"known_as\":\"$gn_json_aka\""
		[[ -n "$json_iqs_threat_tags" ]] && final_json_output+="$json_iqs_threat_tags"
		final_json_output+="},\"fingerprinting\":{"
		[[ -n "$shodan_cpes_json_output" ]] && final_json_output+="\"cpes\":$shodan_cpes_json_output,"
		[[ -n "$shodan_ports_json_output" ]] && final_json_output+="\"ports\":$shodan_ports_json_output,"
		[[ -n "$shodan_tags_json_output" ]] && final_json_output+="\"tags\":$shodan_tags_json_output,"
		[[ -n "$shodan_vulns_json_output" ]] && final_json_output+="\"vulns\":$shodan_vulns_json_output,"
		# truncate last comma
		[[ ${final_json_output: -1} = "," ]] && final_json_output=${final_json_output::-1}
		final_json_output+="}"
		final_json_output+="}"
	else
		# normal output
		[[ -n "$ip_shodan_cpe_data" ]] && printf "${white}%${indent}s${bluebg}CPE${default}%s\n" "├" "${ip_shodan_cpe_data}"
		[[ -n "$ip_shodan_ports_data" ]] && printf "${white}%${indent}s${bluebg}POR${default}%s\n" "├" "${ip_shodan_ports_data}"
		[[ -n "$ip_shodan_tags_data" ]] && printf "${white}%${indent}s${bluebg}TAG${default}%s\n" "├" "${ip_shodan_tags_data}"
		[[ -n "$ip_shodan_cve_data" ]] && printf "${white}%${indent}s${bluebg}CVE${default}%s\n" "├" "${ip_shodan_cve_data}"
		printf "${white}%${indent}s${bluebg}REP${default} ${magenta}%s${default}\n\n" "└" "$ip_rep_data"
	fi
}

ShodanRecon(){
	shodan_starttime=$(date +%s)
	shodan_json_output=""
	curloutput=""
	urllist=""

	# identify target(s) type
	targetlist=$(echo -e "$userinput" | tr ' ' '\n')
	target_count=$(echo -e "$targetlist" | wc -l)
	if [ "$target_count" -gt 1 ]; then
		# user passed multiple targets "e.g. asn -s 1.1.1.1 8.8.8.8"
		userinput="multiple targets"
	fi

	BoxHeader "Shodan scan for $userinput"

	for target in $targetlist; do
		input=$(echo "$target" | sed 's/\/.*//g' | grep -Eo "$ipv4v6regex")
		if [ -z "$input" ]; then
			# Input is not an IP Address. See if it's a hostname (includes at least one dot)
			if echo "$target" | grep -q "\."; then
				target=$(awk -F[/:] '{gsub(".*//", ""); gsub(".*:.*@", ""); print $1}' <<<"$target")
				target=$(ResolveHostnameToIPList "$target")
				[[ -z "$target" ]] && continue # could not resolve hostname
				json_target_type="hostname"
				target=$(grep -v ":" <<<"$target")
				numips=$(wc -l <<<"$target")
				[[ $numips = 1 ]] && s="" || s="es"
			else
				# not an IP, not a hostname
				continue
			fi
		else
			json_target_type="ip"
		fi
		# prepare shodan InternetDB API URL list for every IP in the given CIDR range
		for ip in $target; do
			if grep -q ":" <<<"$ip"; then
				# Shodan has no data for IPv6 addresses
				continue
			fi
			[[ -n "$urllist" ]] && urllist+="\n"
			urllist+=$(nmap -sL -n "$ip" 2>/dev/null | awk '/Nmap scan report/{print "https://internetdb.shodan.io/"$NF}') # cheers https://stackoverflow.com/a/31412705
		done
	done
	[[ -z "$urllist" ]] && PrintErrorAndExit "no valid targets found"
	numtargets=$(echo -e "$urllist" | wc -l)

	firsturl=1
	while true; do
		saved_lasturl="$lasturl"
		lasturl=$(( firsturl + MAX_CONCURRENT_SHODAN_REQUESTS ))
		# check if concurrent Shodan requests setting is > number of IPs yet to scan
		# if so, perform a batch lookup with all the urls and break. Otherwise
		# perform max concurrent lookups, sleep and continue
		if [ "$lasturl" -ge "$numtargets" ]; then
			lasturl="$numtargets"
			LAST_BATCH=true
		fi
		urlbatch=$(echo -e "$urllist" | awk "NR==$firsturl,NR==$lasturl")
		StatusbarMessage "Collecting data for IPs ${bluebg}${firsturl}-${lasturl}${lightgreybg} of ${bluebg}$numtargets${lightgreybg} total ($MAX_CONCURRENT_SHODAN_REQUESTS threads)"
		DebugPrint "${yellow}curl {$(echo -e "$urlbatch" | tr '\n' ',')}${default}"
		batchoutput=$( xargs -P "$MAX_CONCURRENT_SHODAN_REQUESTS" -n 1 curl -s < <(echo -e "$urlbatch") )
		if grep -q "Rate limit exceeded" <<<"$batchoutput"; then
			# rate limit exceeded during current batch of queries, loop while waiting to continue
			retryafter=$(docurl -s -i "https://internetdb.shodan.io/127.0.0.1" | awk '/^retry-after:/ {print $2}' | tr -d '\r\n')
			while [[ ${retryafter} -gt 1 ]]; do
				StatusbarMessage "Shodan rate limit hit during batch ${bluebg}${firsturl}-${lasturl}${lightgreybg}, resuming in ${redbg}${retryafter}${lightgreybg}s"
				sleep 1
				retryafter=$(( retryafter-1 ))
			done
			# retry last batch
			lasturl="$saved_lasturl"
			continue
		else
			curloutput+="$batchoutput"
			[[ "$LAST_BATCH" = true ]] && break
			# enable below to introduce a delay between batches of curl queries to Shodan (could help with rate limiting)
			# sleep .5
			firsturl=$(( lasturl++ ))
		fi
	done
	StatusbarMessage

	# convert single API output results to array, delete IPs for which Shodan had no data available
	json=$(jq -cM --slurp 'del (.[] | select(.ip==null))' <<<"$curloutput")
	if [ "$json" = "[]" ]; then
		final_json_output="$json"
		PrintErrorAndExit "Shodan has no data for $userinput"
	fi

	shodan_json_output="$json"
	[[ "$JSON_OUTPUT" = true ]] && return

	shodan_endtime=$(date +%s)
	shodan_runtime=$((shodan_endtime-shodan_starttime))

	StatusbarMessage "Parsing collected data"
	vulnlist=""
	hostnamelist=""
	portlist=""
	taglist=""
	cpelist=""
	total_hosts_with_vulns=0
	total_hosts_with_ports=0
	total_hosts_with_tags=0
	total_hosts_with_cpe=0
	total_hosts_with_hostnames=0

	# find all IPs in the json having a non-null ".ip" attribute. It means Shodan has some data about that IP.
	interesting_iplist=$(echo -e "$json" | jq -r '.[].ip' | sort | uniq)
	# iterate over interesting IPs
	for ip in $interesting_iplist; do
		output+="\n${white}•${default} $ip"
		attribs=$(jq -r '.[] | select(.ip=="'"$ip"'")| to_entries | .[] | .key + "=" + (.value | @sh)' <<<"$json")
		numattrs=$(grep -Evc "=$|^ip=" <<<"$attribs"); # get number of populated attributes
		# "attribs" contains a list of attributes for a single IP, composed like this:
		#
		# cpes='cpename1' 'cpename2'
		# hostnames='abc.com'
		# ip='1.2.3.4'
		# ports=22 80 8080
		# tags='vpn'
		# vulns='CVE-123' 'CVE-345'

		# iterate over resulting attributes.
		count=0 # will be used to decide which tree symbol to use (├ or └)

		# - hostnames
		ip_hostnames=$(grep -E "^hostnames=" <<<"$attribs" | cut -d '=' -f 2- | tr -d "'" | uniq)
		hostnamelist+=$(echo -e "\n$ip_hostnames" | tr ' ' '\n')
		if [ -n "$ip_hostnames" ]; then
			count=$(( count+1 ))
			[[ "$count" -eq "$numattrs" ]] && treesymbol="└" || treesymbol="├"
			ip_hostnames=$(echo -e "$ip_hostnames" | sed -e 's/ / • /g' -e "s/.\{136\}/&\n               /g")
			total_hosts_with_hostnames=$(( total_hosts_with_hostnames+1 ))
			output+="\n\t${treesymbol}${bluebg} PTR ${default} ${white}$ip_hostnames${default}"
		fi

		# - cpes
		ip_cpes=$(grep -E "^cpes=" <<<"$attribs" | cut -d '=' -f 2- | tr -d "'" | uniq)
		# use more user-friendly names for some CPEs
		ip_cpes=$(echo -e "$ip_cpes" | \
			sed -e 's,cpe:/a:apache:http_server,Apache-HTTPD,g' \
				-e 's,cpe:/o:linux:linux_kernel,[O/S]-Linux,g' \
				-e 's,cpe:/o:microsoft:windows,[O/S]-Microsoft-Windows,g' \
				-e 's,cpe:/o:debian:debian_linux,[O/S]-Debian-Linux,g' \
				-e 's,cpe:/a:microsoft:internet_information_services,Microsoft-IIS,g' \
				-e 's,cpe:/a:microsoft:exchange_server,Microsoft-Exchange,g' \
				-e 's,cpe:/a:openbsd:openssh,OpenSSH,g' \
				-e 's,cpe:/a:igor_sysoev:nginx,Nginx,g' \
				-e 's,cpe:/a:php:php,PHP,g' \
				-e 's,cpe:/a:jquery:jquery,jQuery,g' \
				-e 's,cpe:/a:getbootstrap:bootstrap,Bootstrap,g' \
				-e 's,cpe:/a:pureftpd:pure-ftpd,Pure-FTPd,g' \
				-e 's,cpe:/a:postfix:postfix,Postfix,g' \
				-e 's,cpe:/a:openssl:openssl,Postfix,g' \
				-e 's,cpe:/a:mysql:mysql,MySQL,g' \
			)
		cpelist+=$(echo -e "\n$ip_cpes" | tr ' ' '\n')
		if [ -n "$ip_cpes" ]; then
			count=$(( count+1 ))
			[[ "$count" -eq "$numattrs" ]] && treesymbol="└" || treesymbol="├"
			ip_cpes=$(echo -e "$ip_cpes" | sed -e 's/ / • /g' -e "s/.\{136\}/&\n               /g")
			total_hosts_with_cpe=$(( total_hosts_with_cpe+1 ))
			output+="\n\t${treesymbol}${bluebg} CPE ${default} ${blue}$ip_cpes${default}"
		fi

		# - ports
		ip_ports=$(grep -E "^ports=" <<<"$attribs" | cut -d '=' -f 2- | uniq)
		portlist+=$(echo -e "\n$ip_ports" | tr ' ' '\n')
		if [ -n "$ip_ports" ]; then
			count=$(( count+1 ))
			[[ "$count" -eq "$numattrs" ]] && treesymbol="└" || treesymbol="├"
			ip_ports=$(echo -e "$ip_ports" | sed -e 's/ / • /g' -e "s/.\{136\}/&\n               /g")
			total_hosts_with_ports=$(( total_hosts_with_ports+1 ))
			output+="\n\t${treesymbol}${bluebg} POR ${default} ${green}$ip_ports${default}"
		fi

		# - tags
		ip_tags=$(grep -E "^tags=" <<<"$attribs" | cut -d '=' -f 2- | tr -d "'" | uniq)
		taglist+=$(echo -e "\n$ip_tags" | tr ' ' '\n')
		if [ -n "$ip_tags" ]; then
			count=$(( count+1 ))
			[[ "$count" -eq "$numattrs" ]] && treesymbol="└" || treesymbol="├"
			ip_tags=$(echo -e "$ip_tags" | sed -e 's/ / • /g' -e "s/.\{136\}/&\n               /g")
			total_hosts_with_tags=$(( total_hosts_with_tags+1 ))
			output+="\n\t${treesymbol}${bluebg} TAG ${default} ${yellow}$ip_tags${default}"
		fi

		# - vulns
		ip_vulns=$(grep -E "^vulns=" <<<"$attribs" | cut -d '=' -f 2- | tr -d "'" | uniq)
		vulnlist+=$(echo -e "\n$ip_vulns" | tr ' ' '\n')
		if [ -n "$ip_vulns" ]; then
			count=$(( count+1 ))
			[[ "$count" -eq "$numattrs" ]] && treesymbol="└" || treesymbol="├"
			# ip_vulns=$(echo -e "$ip_vulns" | sed -e 's/ / • /g')
			ip_vulns=$(echo -e "$ip_vulns" | sed -e 's/ / • /g' -e "s/.\{136\}/&\n               /g")
			total_hosts_with_vulns=$(( total_hosts_with_vulns+1 ))
			output+="\n\t${treesymbol}${bluebg} CVE ${default} ${red}$ip_vulns${default}"
		fi

		output+="\n"

	done

	StatusbarMessage
	echo -e "$output"

	final_stats="${default}\n______________________________\n\n"
	final_stats+="${green}$total_hosts_with_ports exposed${default} host"; [[ "$total_hosts_with_ports" != "1" ]] && final_stats+="s"; final_stats+=" found"
	final_stats+="\n${blue}$total_hosts_with_cpe hosts${default} identified with a known CPE"
	final_stats+="\n${yellow}$total_hosts_with_tags tagged${default} host"; [[ "$total_hosts_with_tags" != "1" ]] && final_stats+="s"; final_stats+=" identified"
	final_stats+="\n$total_hosts_with_hostnames hostname"; [[ "$total_hosts_with_hostnames" != "1" ]] && final_stats+="s"; final_stats+=" discovered"
	final_stats+="\n${red}$total_hosts_with_vulns vulnerable${default} host"; [[ "$total_hosts_with_vulns" != "1" ]] && final_stats+="s"; final_stats+=" found"
	final_stats+="\n\n$numtargets host"; [[ "$numtargets" != "1" ]] && final_stats+="s"; final_stats+=" analyzed in $shodan_runtime seconds.\n"

	# display final statistics (non-JSON output mode only)
	BoxHeader "Statistics"

	# top N ports
	echo -e "\n${green}[TOP ${SHODAN_SHOW_TOP_N} Open Ports] \n"
	if [ -z "$portlist" ]; then
		# no ports found
		echo -e "${green}         Nothing found${default}\n"
	else
		for port in $(echo -e "$portlist" | sort | grep -Ev '^$' | uniq -c | sort -rn | head -n "${SHODAN_SHOW_TOP_N}"); do
			porthits=$(awk '{print $1}' <<<"$port")
			portnum=$(awk '{print $2}' <<<"$port")
			portname=$(ResolveWellKnownPort "$portnum")
			[[ -n "$portname" ]] && portname="(${portname})"
			printf "%10s host(s) —> Port %5s %s\n" "$porthits" "$portnum" "$portname"
		done
		echo -e "$default"
	fi

	# top N CPEs
	echo -e "${blue}[TOP ${SHODAN_SHOW_TOP_N} CPEs] \n"
	if [ -z "$cpelist" ]; then
		# no CPEs found
		echo -e "${blue}         Nothing found${default}\n"
	else
		for cpe in $(echo -e "$cpelist" | sort | grep -Ev '^$' |uniq -c | sort -rn | head -n "${SHODAN_SHOW_TOP_N}"); do
			cpehits=$(awk '{print $1}' <<<"$cpe")
			cpefullname=$(awk '{print $2}' <<<"$cpe")
			cpetype=$(echo "$cpefullname" | cut -d ':' -f 2)
			cpename=$(echo "$cpefullname" | cut -d ':' -f 3-)
			case "${cpetype}" in
				"/a")
					type="APP"
				;;
				"/o")
					type="O/S"
				;;
				"/h")
					type="H/W"
				;;
				*)
					type=""
				;;
			esac
			[[ -n "$type" ]] && cpename="[$type] $cpefullname" || cpename="$cpefullname"
			printf "%10s host(s) —> %s\n" "$cpehits" "$cpename"
		done
		echo -e "$default"
	fi
	# top N tags
	echo -e "${yellow}[TOP ${SHODAN_SHOW_TOP_N} Tags] \n"
	if [ -z "$taglist" ]; then
		# no tags found
		echo -e "${yellow}         Nothing found${default}\n"
	else
		for tag in $(echo -e "$taglist" | sort | grep -Ev '^$' | uniq -c | sort -rn | head -n "${SHODAN_SHOW_TOP_N}"); do
			taghits=$(awk '{print $1}' <<<"$tag")
			tagname=$(awk '{print $2}' <<<"$tag")
			printf "%10s host(s) —> %s\n" "$taghits" "$tagname"
		done
		echo -e "$default"
	fi
	# first N hostnames discovered
	echo -e "${white}[First ${SHODAN_SHOW_TOP_N} Hostnames discovered] \n"
	if [ -z "$hostnamelist" ]; then
		# no tags found
		echo -e "${yellow}         Nothing found${default}\n"
	else
		for hostname in $(echo -e "$hostnamelist" | grep -Ev '^$' | head -n "${SHODAN_SHOW_TOP_N}"); do
			printf "         %s\n" "$hostname"
		done
		echo -e "$default"
	fi
	# top N vulnerabilities
	echo -e "${red}[TOP ${SHODAN_SHOW_TOP_N} Vulnerabilities] \n"
	StatusbarMessage "Identifying CVE score and severity for vulnerable hosts"
	cvestats_text=""
	if [ -z "$vulnlist" ]; then
		# no vulns found
		cvestats_text="${red}         Nothing found${default}"
	else
		for cve in $(echo -e "$vulnlist" | sort | grep -Ev '^$' | uniq -c | sort -rn | head -n "${SHODAN_SHOW_TOP_N}"); do
			vulnhits=$(awk '{print $1}' <<<"$cve")
			cvenum=$(awk '{print $2}' <<<"$cve")
			cvejsondata=$(docurl -s "https://services.nvd.nist.gov/rest/json/cve/1.0/$cvenum")
			v3score=$(jq -r '.result.CVE_Items[0].impact.baseMetricV3.cvssV3.baseScore | select(length>0)' <<<"$cvejsondata" 2>/dev/null)
			v3severity=$(jq -r '.result.CVE_Items[0].impact.baseMetricV3.cvssV3.baseSeverity | select(length>0)' <<<"$cvejsondata" 2>/dev/null)
			v2score=$(jq -r '.result.CVE_Items[0].impact.baseMetricV2.cvssV2.baseScore' <<<"$cvejsondata" 2>/dev/null)
			v2severity=$(jq -r '.result.CVE_Items[0].impact.baseMetricV2.severity' <<<"$cvejsondata" 2>/dev/null)
			cvescore=""
			cveseverity=""
			if [ -n "$v3score" ] && [ -n "$v3severity" ]; then
				cvescore="$v3score"
				cveseverity="$v3severity"
			elif [ -n "$v2score" ] && [ -n "$v2severity" ]; then
				cvescore="$v2score"
				cveseverity="$v2severity"
			fi
			if [ "${#cvescore}" -eq 1 ]; then
				cvescore+=".0"
			elif [ "${#cvescore}" -eq 2 ]; then
				cvescore=" $cvescore"
			fi

			case "${cveseverity}" in
				"LOW")
					cvetext="${greenbg}    ${cvescore} (LOW)   ${default}${red}"
				;;
				"MEDIUM")
					cvetext="${yellowbg}  ${cvescore} (MEDIUM)  ${default}${red}"
				;;
				"HIGH")
					cvetext="${redbg}   ${cvescore} (HIGH)   ${default}${red}"
				;;
				"CRITICAL")
					cvetext="${redbg} ${cvescore} (CRITICAL) ${default}${red}"
				;;
				*)
					cvescore="N/A"
					cvetext="${lightgreybg} ${cvescore} (UNKNOWN)  ${default}${red}"
				;;
			esac

			cvestats_text+=$(printf "${red}%10s host(s) —> %-15s %-14s • %s" "$vulnhits" "$cvetext" "$cvenum" "https://nvd.nist.gov/vuln/detail/$cvenum")
			cvestats_text+="\n"
		done
	fi
	StatusbarMessage
	echo -e "$cvestats_text"
	echo -e "$final_stats"
}

BulkGeolocate(){
	# identify target(s) type
	targetlist_allips=$(echo -e "$userinput" | grep -Eo "$ipv4v6regex" | sort)
	top10_ipv4=$(grep -v ":" <<<"$targetlist_allips" | uniq -c | sort -rn | head -n 10)
	top10_ipv6=$(grep ":" <<<"$targetlist_allips" | uniq -c | sort -rn | head -n 10)
	targetlist=$(uniq <<<"$targetlist_allips")
	if [ -n "$targetlist" ]; then
		target_count=$(echo -e "$targetlist" | wc -l)
	else
		PrintErrorAndExit "no valid targets found"
	fi
	if [ "$target_count" -gt 1 ]; then
		# user passed multiple targets "e.g. asn -g 1.1.1.1 8.8.8.8"
		userinput="multiple targets"
	fi

	BoxHeader "Geolocation lookup for $userinput"

	geolocation_json_output=""
	countrylist=""
	firstip=1
	while true; do
		lastip=$(( firstip + 99 ))
		if [ "$lastip" -ge "$target_count" ]; then
			lastip="$target_count"
			LAST_BATCH=true
		fi
		ipbatch=$(echo -en "$targetlist" | awk "NR==$firstip,NR==$lastip")
		StatusbarMessage "Collecting geolocation data for IPs ${bluebg}${firstip}-${lastip}${lightgreybg} of ${bluebg}$target_count${lightgreybg} total"
		ipmap_targets=$(echo -en "$ipbatch" | tr '\n' ',')
		ipapi_targets=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$ipbatch")
		ipmap_output=$(docurl -m15 -s "https://ipmap.ripe.net/api/v1/locate/all?resources=$ipmap_targets")
		if [[ -n $(jq 'select (.error != null) | .error' <<<"$ipmap_output") ]]; then
			ipmap_output=""
		fi
		# Note: the free IP-API tier only supports unencrypted HTTP, not HTTPS
		ipapi_output=$(docurl -m4 -s "http://ip-api.com/batch?fields=query,status,message,country,countryCode,regionName,city" --data ''"$ipapi_targets"'')

		for target in $ipbatch; do
			ip_geo_countryname=""
			json_geo_city=""
			json_geo_region=""
			json_geo_cc=""

			if [ -n "$ipmap_output" ]; then
				IS_ANYCAST=$(jq '.metadata.service.contributions."'"$target"'".latency.metadata.anycast' <<<"$ipmap_output")
				[[ "$IS_ANYCAST" = true ]] && anycast_tag="${yellowbg} ANYCAST ${default}" || anycast_tag=""
				ip_geo_countryname=$(jq -r '.data."'"$target"'" | select( .countryName != null ) | .countryName' <<<"$ipmap_output")
				json_geo_city="$(jq -r '.data."'"$target"'" | select( .cityName != null ) | .cityName' <<<"$ipmap_output")"
				json_geo_region="$(jq -r '.data."'"$target"'" | select( .stateName != null ) | .stateName' <<<"$ipmap_output")"
				json_geo_cc="$(jq -r '.data."'"$target"'" | select( .countryCodeAlpha2 != null ) | .countryCodeAlpha2' <<<"$ipmap_output")"
			fi

			if [ -n "$ip_geo_countryname" ] && [ -n "$json_geo_city" ] && [ -n "$json_geo_region" ] && [ -n "$json_geo_cc" ]; then
				ip_geo_data="$json_geo_city, $json_geo_region, $json_geo_cc"
			else
				# incomplete/no data on RIPE IPMap, fallback to IP-API
				ipapi_status=$(jq -r '.[] | select(.query == "'"$target"'") | .status' <<<"$ipapi_output")
				if [ "$ipapi_status" = "fail" ] && [ "$JSON_OUTPUT" = false ]; then
					ip_geo_countryname="Unknown"
					ip_geo_data="N/A"
				else
					ip_geo_countryname=$(jq -r '.[] | select(.query == "'"$target"'") | .country' <<<"$ipapi_output")
					if [ -z "$ip_geo_countryname" ] && [ "$JSON_OUTPUT" = false ]; then
						ip_geo_countryname="Unknown"
						ip_geo_data="N/A"
					else
						json_geo_city="$(jq -r '.[] | select(.query == "'"$target"'") | .city' <<<"$ipapi_output")"
						json_geo_region="$(jq -r '.[] | select(.query == "'"$target"'") | .regionName' <<<"$ipapi_output")"
						json_geo_cc="$(jq -r '.[] | select(.query == "'"$target"'") | .countryCode' <<<"$ipapi_output")"
						if [ -n "$json_geo_city" ] && [ -n "$json_geo_region" ] && [ -n "$json_geo_cc" ]; then
							ip_geo_data="$json_geo_city, $json_geo_region, $json_geo_cc"
						else
							ip_geo_data="Unknown"
						fi
					fi
				fi
			fi
			if [ "$ip_geo_countryname" = "Unknown" ]; then
				namecolor="${red}"
				countrycolor="${red}"
			else
				namecolor="${white}"
				countrycolor="${green}"
			fi
			if [ "$JSON_OUTPUT" = true ]; then
				[[ -n "$geolocation_json_output" ]] && geolocation_json_output+=","
				geolocation_json_output+="{\"ip\":\"$target\""
				geolocation_json_output+=",\"city\":\"$json_geo_city\""
				geolocation_json_output+=",\"region\":\"$json_geo_region\""
				geolocation_json_output+=",\"country\":\"$ip_geo_countryname\""
				geolocation_json_output+=",\"cc\":\"$json_geo_cc\""
				geolocation_json_output+=",\"hits\":$(grep -c "$target" <<<"$targetlist_allips")"
				[[ "$IS_ANYCAST" = true ]] && geolocation_json_output+=",\"is_anycast\": true"
				geolocation_json_output+="}"
			else
				final_output+=$(printf "${white}%-16s${default}: ${namecolor}%s${default} (${countrycolor}%s${default}) %s" "$target" "$ip_geo_data" "$ip_geo_countryname" "$anycast_tag\n")
				countrylist+="\n$ip_geo_countryname"
			fi
		done

		[[ "$LAST_BATCH" = true ]] && break
		firstip=$(( lastip++ ))
	done

	StatusbarMessage

	[[ "$JSON_OUTPUT" = true ]] && return

	echo -en "${final_output}"

	# top 10 IPs
	if [ -n "$top10_ipv4" ]; then
		BoxHeader "Top 10 IPv4 by number of hits"
		for entry in $top10_ipv4; do
			iphits=$(awk '{print $1}' <<<"$entry")
			ipaddr=$(awk '{ print substr($0, index($0,$2)) }' <<<"$entry")
			printf "${white}%16s appears ${magenta}%s${default} time%s\n" "$ipaddr" "$iphits" "$([[ "$iphits" != "1" ]] && echo -n "s")"
		done
	fi
	if [ -n "$top10_ipv6" ]; then
		BoxHeader "Top 10 IPv6 by number of hits"
		for entry in $top10_ipv6; do
			iphits=$(awk '{print $1}' <<<"$entry")
			ipaddr=$(awk '{ print substr($0, index($0,$2)) }' <<<"$entry")
			printf "${white}%16s appears ${magenta}%s${default} time%s\n" "$ipaddr" "$iphits" "$([[ "$iphits" != "1" ]] && echo -n "s")"
		done
	fi

	# draw countries bar chart
	BoxHeader "Country stats"
	DrawChart "$countrylist" "IP"
}

DrawChart(){
	# draws a bar chart for the occurrences of values from a list.
	# $1 must be a list of values (not necessarily sorted)
	# $2 must be the unit name of the bars (singular. A final 's' is added for bars whose value is > 1)
	# [optional] $3 can be the number of items to display (i.e. TOP n)
	inputlist="$1"
	unitname="$2"
	[[ -n "$3" ]] && topn="$3" || topn="0"
	sorted_input=""
	declare -A valuearray # associative array
	declare -a sorted_input # simple array, to be used as an index into valuearray
	for item in $(echo -e "$inputlist" | sort | grep -Ev '^$' | uniq -c | sort -rn); do
		itemhits=$(awk '{print $1}' <<<"$item")
		itemname=$(awk '{ print substr($0, index($0,$2)) }' <<<"$item")
		valuearray["$itemname"]="$itemhits"
		sorted_input+=("$itemname")
	done

	total_unique_names="${#sorted_input[@]}"
	longest_itemname=$(echo -e "$inputlist" | wc -L)
	count=0
	while true; do
		item=${sorted_input[$count]}
		# incrementally choose color for the bar and index for the item array entry - skip 0 (black)
		[[ "$MONOCHROME_MODE" = false ]] && tput setaf $(( count + 1 ))
		itemhits="${valuearray[$item]}"
		spacing="$itemhits"
		[[ "$itemhits" -gt "$terminal_width" ]] && spacing=$(( terminal_width-(14+longest_itemname) ))
		printf " %${longest_itemname}s " "$item"
		printf "█%.0s" $(seq "$spacing")
		printf " %s ${unitname}%s\n" "$itemhits" "$([[ "$itemhits" != "1" ]] && echo -n "s")"
		(( count++ ))
		if [ "$topn" != "0" ] && [ "$count" -ge "$topn" ]; then
			break
		elif [ "$count" -ge "$total_unique_names" ]; then
			break
		fi
	done
	echo -e "${default}"
}

PrintJsonOutput(){
	DisableColors
	endtime=$(date +%s)
	runtime=$((endtime-starttime))
	json_to_print="{\"target\":\"$userinput\","
	json_to_print+="\"target_type\":\"$json_target_type\","
	json_to_print+="\"result\":\"$status_json_output\","
	json_to_print+="\"reason\":\"$reason_json_output\","
	json_to_print+="\"version\":\"$ASN_VERSION\","
	json_to_print+="\"request_time\":\"$json_request_time\","
	json_to_print+="\"request_duration\":$runtime,"
	json_to_print+="\"result_count\":$json_resultcount,"
	if [ "$RECON_MODE" = true ] || [ "$BGP_UPSTREAM_MODE" = true ]; then
		# we already have an array as a final json output, append it as-is
		json_to_print+="\"results\":${final_json_output}}"
	else
		json_to_print+="\"results\":[${final_json_output}]}"
	fi
	[[ "$JSON_PRETTY" = true ]] && json_to_print=$(jq -M '.' <<<"$json_to_print") || json_to_print=$(jq -c '.' <<<"$json_to_print")
	echo -e "$json_to_print"
}

ResolveWellKnownPort(){
	# input: port number, output: service name
	[[ -n "$WELL_KNOWN_PORTS" ]] && awk "/\t$1\/(tc|ud)p/{print \$1; exit}" <<<"$WELL_KNOWN_PORTS"
}

RPKILookup(){
	# $1=asn, $2=prefix
	found_rpkivalidity=""
	INVALID_ROA=false
	rpki_apioutput=$(docurl -s "https://stat.ripe.net/data/rpki-validation/data.json?resource=$1&prefix=$2&sourceapp=nitefood-asn")
	is_valid_json=$(jq type <<<"$rpki_apioutput" 2>/dev/null)
	if [ -n "$is_valid_json" ]; then
		found_rpkivalidity=$(jq -r '.data.status' <<<"$rpki_apioutput" | tr '[:lower:]' '[:upper:]')
		found_rpkiroacount=$(jq '.data.validating_roas | length' <<<"$rpki_apioutput")
		roacount_json_output="$found_rpkiroacount"
		found_rpkiprefix=$(jq -r '.data.validating_roas[0].prefix' <<<"$rpki_apioutput")
		found_rpkiorigins=$(jq -r '.data.validating_roas[] | select (.prefix=="'"$found_rpkiprefix"'") | .origin' <<<"$rpki_apioutput")
		found_rpkiorigin="["
		origin_count=0
		for origin in $found_rpkiorigins; do
			[[ "$origin_count" -gt 0 ]] && found_rpkiorigin+=", "
			found_rpkiorigin+="AS$origin"
			(( origin_count++ ))
		done
		found_rpkiorigin+="]"

		found_rpkimaxlength=$(jq -r '.data.validating_roas[0].max_length' <<<"$rpki_apioutput")
		# TODO: iterate over ROAs (.data.validatingRoas[]) to give deeper source RIR insight
		#found_rpkisource=$(echo "$rpki_apioutput" | jq -r '.data.validatingRoas[0].source')
		case "$found_rpkivalidity" in
			"VALID")
				[[ "${found_rpkiroacount}" -gt 1 ]] && s="s" || s=""
				rpki_output="${green}✓ VALID (${found_rpkiroacount} ROA$s found)${default}"
				roavalidity_json_output="valid"
				;;
			"UNKNOWN")
				rpki_output="${yellow}✓ UNKNOWN (no ROAs found)${default}"
				roavalidity_json_output="unknown"
				;;
			"INVALID_ASN")
				INVALID_ROA=true
				roavalidity_json_output="invalid"
				if [ "$found_rpkiorigin" = "0" ]; then
					rpki_output="${red}❌ ${found_rpkivalidity} (no Origin authorized to announce Prefix '${found_rpkiprefix}' with Max-Length=${found_rpkimaxlength})${default}"
				else
					rpki_output="${red}❌ ${found_rpkivalidity} (expected Origin(s): ${found_rpkiorigin} for Prefix '${found_rpkiprefix}' with Max-Length=${found_rpkimaxlength})${default}"
				fi
				;;
			"INVALID_LENGTH")
				INVALID_ROA=true
				roavalidity_json_output="invalid"
				rpki_output="${red}❌ ${found_rpkivalidity} (expected Max-Length=${found_rpkimaxlength} for Prefix '${found_rpkiprefix}')${default}"
				;;
		esac
	else
		rpki_output="${yellow}? (WRONG RPKI DATA or problem accessing RIPEStat API)${default}"
		roacount_json_output="-1"
		roavalidity_json_output="unknown (API error)"
	fi
}

IsIXP() {
	# input ($1) is an IPv4/v6.
	ixp_full_ix_data=""
	ixp_data=""
	ixp_geo=""
	input_is_ipv6=false
	if [ "$IXP_DETECTION" = true ]; then
		echo -e "$1" | grep -q ':' && input_is_ipv6=true
		# Update IXP prefixes from PeeringDB if necessary
		# use the appropriate (v4/v6) IXP prefix dataset
		if [ "$input_is_ipv6" = false ]; then
			# if input is an IPv4, speedup lookups further by grabbing only IXP prefixes starting with the same two octets
			# we can afford filtering based on the first two octets since the largest individual IXP prefix is around /20
			first_octets=$(echo "${1}." | cut -d '.' -f 1,2)
			# see if the PEERINGDB_CACHED_DATASETS array already an entry for this prefix's first two octets.
			# If not, fetch the relevant IXP prefix dataset from PeeringDB and store it in the PEERINGDB_CACHED_DATASETS
			if [ -n "${PEERINGDB_CACHED_DATASETS[$first_octets]}" ]; then
				peeringdb_dataset="${PEERINGDB_CACHED_DATASETS[$first_octets]}"
			else
				peeringdb_ipv4_dataset=$(docurl -s "https://www.peeringdb.com/api/ixpfx?prefix__startswith=$first_octets&protocol__in=IPv4")
				peeringdb_dataset="$peeringdb_ipv4_dataset"
				# store the IXP dataset in the PEERINGDB_CACHED_DATASETS array
				PEERINGDB_CACHED_DATASETS[$first_octets]="$peeringdb_dataset"
			fi
		else
			# only fetch IPv6 dataset once, since we don't filter it for prefixes
			if [ -z "$peeringdb_ipv6_dataset" ]; then
				peeringdb_ipv6_dataset=$(docurl -s "https://www.peeringdb.com/api/ixpfx?protocol__in=IPv6")
			fi
			peeringdb_dataset="$peeringdb_ipv6_dataset"
		fi
		ixp_prefixes=$(jq -r '.data[].prefix' <<<"$peeringdb_dataset")
		# search for input prefix through PeeringDB IXP prefix list
		for prefix in $ixp_prefixes; do
			if echo "$1" | grepcidr -f <(echo "$prefix") &>/dev/null; then
				# the IP is part of an IXP prefix
				ixlan_id=$(jq -r '.data[] | select(.prefix == "'"$prefix"'") | .ixlan_id' <<<"$peeringdb_dataset")
				# see if the PEERINGDB_CACHED_IXP_DATA array already has an entry with the IXP details for this ixlan_id.
				# If not, fetch the full IXP data from PeeringDB and store it in the PEERINGDB_CACHED_IXP_DATA
				if [ -n "${PEERINGDB_CACHED_IXP_DATA[$ixlan_id]}" ]; then
					ixp_full_ix_data="${PEERINGDB_CACHED_IXP_DATA[$ixlan_id]}"
				else
					# Query PeeringDB to match an IXP for that prefix.
					ixp_full_ix_data=$(docurl -s "https://www.peeringdb.com/api/ix/$ixlan_id")
					# store the IXP data in the PEERINGDB_CACHED_IXP_DATA array
					PEERINGDB_CACHED_IXP_DATA[$ixlan_id]="$ixp_full_ix_data"
				fi
				ixp_data=$(jq -r '.data[0].name, .data[0].name_long' <<<"$ixp_full_ix_data" | paste -sd '|' - | awk -F'|' '{print $1 " (" $2 ")"}')
				ixp_geo=$(jq -r '.data[0].org.city' <<<"$ixp_full_ix_data")
				ixp_state=$(jq -r '.data[0].org.state' <<<"$ixp_full_ix_data")
				ip_type_data=" ${lightgreybg} IXP ${default}"
				[[ -n "$ixp_state" ]] && ixp_geo+=" ($ixp_state)"
				[[ "$IS_ASN_CHILD" = true ]] && ixp_data="<a href=\"https://www.peeringdb.com/ix/$ixlan_id\" target=\"_blank\" class=\"hidden_underline\" style=\"color: $htmlblue;\">$ixp_data</a>"
				break
			fi
		done
	fi
}

GetIXPresence(){
	asn="$1"
	ixps=""
	outputix=""
	json_ixps=""
	netlist=$(docurl -s "https://www.peeringdb.com/api/net?asn__in=$asn" | jq -r '.data[].id')
	if [ -n "$netlist" ]; then
		for net in $netlist; do
			if [ "$IS_ASN_CHILD" = true ] && [ "$JSON_OUTPUT" = false ]; then
				ixps+=$(docurl -s "https://www.peeringdb.com/api/net/$net" | jq -r '.data[].netixlan_set[] | "<a href=\"https://www.peeringdb.com/ix/\(.ix_id)\" target=\"_blank\" class=\"hidden_underline\" style=\"color: '"$htmlblue"';\">\(.name)</a>"')
			else
				ixps+=$(docurl -s "https://www.peeringdb.com/api/net/$net" | jq -r '.data[].netixlan_set[].name')
			fi
		done
		if [ -n "$ixps" ]; then
			for ix in $(echo "$ixps" | sort -u); do
				[[ -n "$outputix" ]] && outputix+=" • "
				outputix+="${blue}${ix}${default}"
			done
		else
			outputix="${redbg} NONE ${default}"
		fi
	else
		outputix="${redbg} NONE ${default}"
	fi
	if [ "$JSON_OUTPUT" = true ]; then
		# json output
		json_ixps=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$ixps")
	else
		# normal output
		echo -e "$outputix"
	fi
}

GetCAIDARank(){
	# see if we already have CAIDA rank cached for this AS
	asn="$1"
	if [ -n "${CAIDARANK_CACHED_AS_DATA[$asn]}" ]; then
		caida_data="${CAIDARANK_CACHED_AS_DATA[$asn]}"
	else
		caida_data=$(docurl -s "https://api.asrank.caida.org/dev/restful/asns/${asn}")
		# store the rank in the CAIDARANK_CACHED_AS_DATA array
		CAIDARANK_CACHED_AS_DATA[$asn]="$caida_data"
	fi
	caida_asrank=$(jq -r '.data.asn.rank' <<<"$caida_data")
	caida_rir=$(jq -r '.data.asn.source' <<<"$caida_data")
	case "${caida_rir}" in
		"AFRINIC")
			caida_rir="AFRINIC ${dim}(Africa)${default}"
		;;
		"APNIC")
			caida_rir="APNIC ${dim}(Asia Pacific)${default}"
		;;
		"ARIN")
			caida_rir="ARIN ${dim}(USA, Canada, many Caribbean and North Atlantic islands)${default}"
		;;
		"LACNIC")
			caida_rir="LACNIC ${dim}(Latin America and the Caribbean)${default}"
		;;
		"RIPE")
			caida_rir="RIPE ${dim}(Europe, the Middle East and parts of Central Asia)${default}"
		;;
	esac

	caida_customercone=$(jq -r '.data.asn.cone.numberAsns' <<<"$caida_data")
	caida_degree_total=$(jq -r '.data.asn.asnDegree.total' <<<"$caida_data")
	caida_degree_customer=$(jq -r '.data.asn.asnDegree.customer' <<<"$caida_data")
	caida_degree_peer=$(jq -r '.data.asn.asnDegree.peer' <<<"$caida_data")
	caida_degree_provider=$(jq -r '.data.asn.asnDegree.provider' <<<"$caida_data")
	# caida_asrank_color="${dim}"
	caida_asrank_text=""
	if (( caida_asrank <= 10 )); then
		caida_asrank_text=" ${lightgreybg} TOP 10 AS ${default}"
	elif (( caida_asrank <= 35 )); then
		caida_asrank_text=" ${lightgreybg} TOP 35 AS ${default}"
	elif (( caida_asrank <= 100 )); then
		caida_asrank_text=" ${lightgreybg} TOP 100 AS ${default}"
	elif (( caida_asrank <= 500)); then
		caida_asrank_text=" ${lightgreybg} TOP 500 AS ${default}"
	elif (( caida_asrank <= 1000)); then
		caida_asrank_text=" ${lightgreybg} TOP 1000 AS ${default}"
	fi
	caida_asrank_recap="${dim}#${white}${caida_asrank}${caida_asrank_text}"
}

IPGeoRepLookup(){
	if [ -n "$mtr_output" ] && [ "$DETAILED_TRACE" = false ]; then
		# skip geolocation and reputation lookups for individual trace hops in non-detailed mode
		return
	fi

	ip_geo_data=""
	ip_geo_countryname=""
	geo_city_json_output=""
	geo_region_json_output=""
	geo_country_json_output=""
	geo_cc_json_output=""
	local ipmap_city
	local ipmap_region
	local ipmap_cc
	local ipmap_country_name
	local ipapi_city
	local ipapi_region
	local ipapi_cc
	local ipapi_countryname
	local ipmap_location_data
	local ipapi_output
	local ipapi_status
	local ipapi_errmsg

	StatusbarMessage "Collecting geolocation and classification data"

	# fetch preferred geolocation and anycast data from RIPE IPmap
	ipmap_output=$(docurl -m4 -s "https://ipmap.ripe.net/api/v1/locate/$1/best")

	# fetch fallback geolocation and ip type (is mobile?) data from ip-api.com
	# Note: the free IP-API tier only supports unencrypted HTTP, not HTTPS
	ipapi_output=$(docurl -m4 -s "http://ip-api.com/json/$1?fields=status,message,country,countryCode,regionName,city,mobile,proxy,hosting")
	ipapi_status=$(jq -r '.status' <<<"$ipapi_output")
	if [ "$ipapi_status" = "fail" ]; then
		ipapi_errmsg=$(jq -r '.message' <<<"$ipapi_output")
		ip_rep_data="${red}IP-API ERROR:${default} ${ipapi_errmsg}"
	else
		IS_MOBILE=$(jq -r '.mobile' <<<"$ipapi_output")
		IS_PROXY=$(jq -r '.proxy' <<<"$ipapi_output")
		IS_HOSTING=$(jq -r '.hosting' <<<"$ipapi_output")
	fi

	IS_ANYCAST=""
	if [[ -z $(jq 'select (.error != null) | .error' <<<"$ipmap_output") ]]; then
		IS_ANYCAST=$(jq '.metadata.service.contributions."'"$1"'".engines[] | select (.engine=="latency") | .metadata.anycast' <<<"$ipmap_output")
	fi

	ipmap_location_data=$(jq 'select (.location != null) | .location' <<<"$ipmap_output")
	if [ -n "$ipmap_location_data" ]; then
		# RIPE IPmap has (at least some) geo data about this address, check city/region
		ipmap_city=$(jq -r 'select (.cityNameAscii != null) | .cityNameAscii' <<<"$ipmap_location_data")
		ipmap_region=$(jq -r 'select (.stateName != null) | .stateName' <<<"$ipmap_location_data")
	fi
	flag_icon_cc="" # will be used in HTML reports served over HTTP
	if [ -n "$ipmap_city" ] && [ -n "$ipmap_region" ]; then
		# RIPE IPmap has full geo data, continue
		ipmap_cc=$(jq -r '.countryCodeAlpha2' <<<"$ipmap_location_data")
		ipmap_country_name=$(jq -r '.countryName' <<<"$ipmap_location_data")
		# populate json output fields from ipmap output
		geo_city_json_output="$ipmap_city"
		geo_region_json_output="$ipmap_region"
		geo_country_json_output="$ipmap_country_name"
		geo_cc_json_output="$ipmap_cc"
		if [ -n "$ipmap_city" ] && [ -n "$ipmap_region" ] && [ -n "$ipmap_cc" ]; then
			ip_geo_data="$ipmap_city, $ipmap_region ($ipmap_cc)"
			flag_icon_cc=$(tr '[:upper:]' '[:lower:]' <<<"$ipmap_cc")
			ip_geo_countryname="$ipmap_country_name"
		elif [ -n "$ipmap_region" ] && [ -n "$ipmap_country_name" ]; then
			ip_geo_data="$ipmap_region ($ipmap_country_name)"
			ip_geo_countryname="$ipmap_country_name"
		elif [ -n "$ipmap_country_name" ]; then
			ip_geo_data="$ipmap_country_name"
			ip_geo_countryname="$ipmap_country_name"
		fi
	elif [ "$ipapi_status" = "success" ]; then
		# IPmap has incomplete/no data about this address, fallback to ip-api.com
		ipapi_city=$(jq -r '.city' <<<"$ipapi_output")
		ipapi_region=$(jq -r '.regionName' <<<"$ipapi_output")
		ipapi_cc=$(jq -r '.countryCode' <<<"$ipapi_output")
		ipapi_countryname=$(jq -r '.country' <<<"$ipapi_output")
		# populate json output fields from ip-api output
		geo_city_json_output="$ipapi_city"
		geo_region_json_output="$ipapi_region"
		geo_country_json_output="$ipapi_countryname"
		geo_cc_json_output="$ipapi_cc"
		if [ -n "$ipapi_city" ] && [ -n "$ipapi_region" ] && [ -n "$ipapi_cc" ]; then
			ip_geo_data="$ipapi_city, $ipapi_region ($ipapi_cc)"
			ip_geo_countryname="$ipapi_countryname"
			flag_icon_cc=$(tr '[:upper:]' '[:lower:]' <<<"$ipapi_cc")
		elif [ -n "$ipapi_region" ] && [ -n "$ipapi_countryname" ]; then
			ip_geo_data="$ipapi_region ($ipapi_countryname)"
			ip_geo_countryname="$ipapi_countryname"
		elif [ -n "$ipapi_countryname" ]; then
			ip_geo_data="$ipapi_countryname"
			ip_geo_countryname="$ipapi_countryname"
		fi
	fi

	# IP type identification
	ip_type_data=""
	if [ "$IS_ANYCAST" = true ]; then
		ip_type_data+=" ${yellowbg} Anycast IP ${default}"
		ip_type_json_output+=",\"is_anycast\":true"
	else
		ip_type_json_output+=",\"is_anycast\":false"
	fi
	if [ "$IS_MOBILE" = true ]; then
		ip_type_data+=" ${yellowbg} Mobile network IP ${default}"
		ip_type_json_output+=",\"is_mobile\":true"
	else
		ip_type_json_output+=",\"is_mobile\":false"
	fi
	if [ "$IS_PROXY" = true ]; then
		ip_type_data+=" ${yellowbg} Proxy host ${default}"
		ip_type_json_output+=",\"is_proxy\":true"
	else
		ip_type_json_output+=",\"is_proxy\":false"
	fi
	# fetch detailed DC informations (incolumitas.com Datacenter IP Address API)
	incolumitas_dcdata=$(docurl -m2 -s "https://api.incolumitas.com/datacenter?ip=$1")
	dcname=$(jq -r 'select (.datacenter.datacenter != null) | .datacenter.datacenter' <<<"$incolumitas_dcdata" 2>/dev/null)
	dcregion=$(jq -r 'select (.datacenter.region != null) | .datacenter.region' <<<"$incolumitas_dcdata" 2>/dev/null)
	if [ -n "$dcname" ]; then
		# incolumitas.com has details regarding this DC
		ip_type_data+=" ${yellowbg} DC ${default}${yellow} $dcname"
		ip_type_json_output+=",\"is_dc\":true"
		ip_type_json_output+=",\"dc_details\":{\"dc_name\":\"$dcname\""
		if [ -n "$dcregion" ]; then
			ip_type_data+=" ($dcregion)"
			ip_type_json_output+=",\"dc_region\":\"$dcregion\""
		fi
		ip_type_json_output+="}"
		ip_type_data+="${default}"
	elif [ "$IS_HOSTING" = true ]; then
		# fallback to IP-API DC detection
		ip_type_data+=" ${yellowbg} Hosting/DC ${default}"
		ip_type_json_output+=",\"is_dc\":true"
	else
		ip_type_json_output+=",\"is_dc\":false"
	fi
	# Reputation lookup (stopforumspam.org), noise classification (greynoise.io) and threat analisys (ipqualityscore.com)
	ip_rep_data="${green}✓ NONE${default}"
	json_rep="none"
	json_iqs_threat_score=""
	json_iqs_threat_tags=""
	is_blacklisted=$(docurl -m4 -s "https://api.stopforumspam.org/api?json&ip=$1" | jq -r '.ip.appears')
	if [ "$is_blacklisted" = "1" ]; then
		# IP is blacklisted by StopForumSpam
		json_rep="bad"
		ip_rep_data="${red}❌ BAD (on stopforumspam.org)${default}"
	fi
	if [ -n "$IQS_TOKEN" ]; then
		if [ "$is_blacklisted" = "1" ] || [ "$IQS_ALWAYS_QUERY" = true ]; then
			# Lookup detailed reputation data on IPQualityScore
			iqs_query_url="https://ipqualityscore.com/api/json/ip/$IQS_TOKEN/$1"
			[[ -n "$IQS_CUSTOM_SETTINGS" ]] && iqs_query_url+="?$IQS_CUSTOM_SETTINGS"
			iqs_output=$(docurl -m4 -s "$iqs_query_url")
			iqs_success=$(jq -r '.success' <<<"$iqs_output")
			if [ "$iqs_success" = true ]; then
				iqs_score=$(jq -r '.fraud_score' <<<"$iqs_output")
				iqs_proxy=$(jq -r '.proxy' <<<"$iqs_output")
				iqs_vpn=$(jq -r '.active_vpn' <<<"$iqs_output")
				iqs_tor=$(jq -r '.active_tor' <<<"$iqs_output")
				iqs_recentabuse=$(jq -r '.recent_abuse' <<<"$iqs_output")
				iqs_bot=$(jq -r '.bot_status' <<<"$iqs_output")
				iqs_crawler=$(jq -r '.is_crawler' <<<"$iqs_output")
				json_iqs_threat_score+=",\"threat_score\":\"$iqs_score\""
				if [ "$iqs_score" -lt 40 ]; then
					ip_rep_data="✓ GOOD"
					ip_rep_color="$green"
					json_rep="good"
				elif [ "$iqs_score" -lt 75 ]; then
					ip_rep_data="✓ AVERAGE"
					ip_rep_color="$green"
					json_rep="average"
				elif [ "$iqs_score" -lt 85 ]; then
					ip_rep_data="! SUSPICIOUS"
					ip_rep_color="$yellow"
					json_rep="suspicious"
				else
					ip_rep_data="❌ BAD"
					ip_rep_color="$red"
					json_rep="bad"
				fi
				ip_rep_data="${ip_rep_color}${ip_rep_data} (Threat Score ${iqs_score}%)${default}"
				[[ "$iqs_recentabuse" = true ]] && ip_rep_data+=" ${redbg} RECENT ABUSER ${default}"; json_iqs_threat_tags+=",\"is_recent_abuser\": true"
				[[ "$iqs_bot" = true ]] && ip_rep_data+=" ${redbg} BOT ${default}"; json_iqs_threat_tags+=",\"is_bot\": true"
				[[ "$iqs_proxy" = true ]] && ip_rep_data+=" ${redbg} PROXY ${default}"; json_iqs_threat_tags+=",\"is_proxy\": true"
				[[ "$iqs_vpn" = true ]] && ip_rep_data+=" ${redbg} VPN ${default}"; json_iqs_threat_tags+=",\"is_vpn\": true"
				[[ "$iqs_tor" = true ]] && ip_rep_data+=" ${redbg} TOR EXIT NODE ${default}"; json_iqs_threat_tags+=",\"is_tor\": true"
				[[ "$iqs_crawler" = true ]] && ip_rep_data+=" ${redbg} CRAWLER ${default}"; json_iqs_threat_tags+=",\"is_crawler\": true"
			else
				iqs_errmsg=$(jq -r '.message' <<<"$iqs_output")
				ip_rep_data+=" ${redbg} ERR ${default} (IpQualityScore API said: $iqs_errmsg)"
			fi
		fi
	fi
	# GreyNoise lookup
	greynoise_data=$(docurl -m5 -s "https://api.greynoise.io/v3/community/$1")
	gn_noisy=false
	gn_riot=""
	gn_classification=""
	gn_name=""
	gn_json_is_knowngood=""
	gn_json_is_knownbad=""
	gn_json_aka=""
	if [ -n "$greynoise_data" ]; then
		gn_noisy=$(jq -r 'select (.noise != null) | .noise' <<<"$greynoise_data")
		gn_riot=$(jq -r 'select (.riot != null) | .riot' <<<"$greynoise_data")
		gn_classification=$(jq -r 'select (.classification != null) | .classification' <<<"$greynoise_data")
		gn_name=$(jq -r 'select (.name != null) | .name' <<<"$greynoise_data")
		if [ "$gn_name" = "unknown" ]; then
			gn_name="${default}"
		else
			gn_json_aka="$gn_name"
			gn_name="as \"$gn_name\" ${default}"
		fi
		if [ "$gn_riot" = "true" ] || [ "$gn_classification" = "benign" ]; then
			# GreyNoise known-good
			ip_rep_data="${green}✓${default} ${greenbg} KNOWN GOOD $gn_name"
			json_rep="good"
			gn_json_is_knowngood=true
			[[ "$gn_noisy" = "true" ]] && ip_rep_data+=" ${yellowbg} SEEN SCANNING ${default}"
		elif [ "$gn_classification" = "malicious" ]; then
			# GreyNoise known-bad
			[[ "$is_blacklisted" != "1" ]] && ip_rep_data="${red}❌ BAD${default}" # tag the IP with a bad REP, it wasn't caught by StopForumSpam earlier
			ip_rep_data+=" ${redbg} SCANNER $gn_name"
			json_rep="bad"
			gn_json_is_knownbad=true
		else
			# GreyNoise not listed, or tagged as "noisy" but not explicitly good or bad
			[[ "$gn_noisy" = "true" ]] && ip_rep_data+=" ${yellowbg} SEEN SCANNING ${default}"
		fi
	fi

	StatusbarMessage
}

IPShodanLookup(){
	# Shodan InternetDB lookup
	if [ -n "$mtr_output" ] && [ "$DETAILED_TRACE" = false ]; then
		# skip Shodan lookup for individual trace hops in non-detailed mode
		return
	fi
	ip_shodan_cpe_data=""
	ip_shodan_ports_data=""
	ip_shodan_tags_data=""
	ip_shodan_cve_data=""
	shodan_cpes_json_output=""
	shodan_ports_json_output=""
	shodan_tags_json_output=""
	shodan_vulns_json_output=""
	StatusbarMessage "Collecting open ports, CPE and CVE data"
	shodan_data=$(docurl -m5 -s "https://internetdb.shodan.io/$1" | grep -v "No information available")
	if [ -n "$shodan_data" ]; then
		shodan_cpes=$(jq -r '.cpes[]' <<<"$shodan_data" 2>/dev/null)
		shodan_cpes_json_output=$(jq -cM 'select (.cpes | length > 0) | .cpes' <<<"$shodan_data" 2>/dev/null)
		shodan_ports=$(jq -r '.ports[]' <<<"$shodan_data" 2>/dev/null)
		shodan_ports_json_output=$(jq -cM 'select (.ports | length > 0) | .ports' <<<"$shodan_data" 2>/dev/null)
		shodan_tags=$(jq -r '.tags[]' <<<"$shodan_data" 2>/dev/null)
		shodan_tags_json_output=$(jq -cM 'select (.tags | length > 0) | .tags' <<<"$shodan_data" 2>/dev/null)
		shodan_cve_count=$(jq '.vulns | length' <<<"$shodan_data" 2>/dev/null)
		shodan_vulns_json_output=$(jq -cM 'select (.vulns | length > 0) | .vulns' <<<"$shodan_data" 2>/dev/null)

		# fetch CPE types, possible values:
		# a for Applications, h for Hardware, o for Operating Systems
		for cpe in $shodan_cpes; do
			cpetype=$(echo "$cpe" | cut -d ':' -f 2)
			cpename=$(echo "$cpe" | cut -d ':' -f 3-)
			case "${cpetype}" in
				"/a")
					type="APP"
				;;
				"/o")
					type="O/S"
				;;
				"/h")
					type="H/W"
				;;
				*)
					type="UNK"
				;;
			esac
			ip_shodan_cpe_data+="${white} [${blue}$type: ${white}$cpename]${default}"
		done

		# fetch open ports
		ip_shodan_ports_data=""
		for port in $shodan_ports; do
			[[ -n "$ip_shodan_ports_data" ]] && ip_shodan_ports_data+="," || ip_shodan_ports_data=" ${green}Open ports:"
			ip_shodan_ports_data+=" $port"
		done
		[[ -n "$ip_shodan_ports_data" ]] && ip_shodan_ports_data+="${default}"

		# fetch Shodan tags
		ip_shodan_tags_data=""
		for tag in $shodan_tags; do
			ip_shodan_tags_data+=" ${lightgreybg} $tag ${default}"
		done

		# fetch Shodan CVE count
		ip_shodan_cve_data=""
		if [ -n "$shodan_cve_count" ] && [ "$shodan_cve_count" != "0" ]; then
			[[ "$shodan_cve_count" != "1" ]] && vulntext="VULNERABILITIES" || vulntext="VULNERABILITY"
			ip_shodan_cve_data+=" ${redbg} $shodan_cve_count $vulntext FOUND ${default} (check "
			[[ "$IS_ASN_CHILD" = true ]] && ip_shodan_cve_data+="<a href=\"https://internetdb.shodan.io/$1\" target=\"_blank\" \">Shodan</a>)" || ip_shodan_cve_data+="https://internetdb.shodan.io/$1)"
		fi
	fi

	StatusbarMessage
}

PwhoisListPrefixesForOrg(){
	# list all IPv4 prefixes on pWhois based on an Org-Name
	# $1 = Org-Name handle
	[[ "$HAVE_IPCALC" = false ]] && return
	org="$1"
	full_org_search_data=$(whois -h whois.pwhois.org "registry org-name=$org")
	orgids=$(echo -e "$full_org_search_data" | grep -i -E -B1 "Org-Name: $org$" | grep "Org-ID" | cut -d ':' -f 2- | sed 's/^ //g')
	# assemble bulk pWhois query
	pwhois_bulk_query="begin\n"
	for orgid in $orgids; do
		pwhois_bulk_query+="netblock org-id=${orgid}\n"
	done
	pwhois_bulk_query+="end"
	# query pWhois
	for prefix in $(echo -e "$pwhois_bulk_query" | ncat whois.pwhois.org 43 | grep -E "^\*>"); do
		iprange=$(echo -e "$prefix" | cut -d '>' -f 2 | cut -d '|' -f 1 | tr -d ' ')
		IpcalcDeaggregate "$iprange"
	done
}

BGPUpstreamLookup(){
	# retrieve likely upstream/transit autonomous system(s) for this IP address
	final_json_output="[]"
	if [ "$IS_BOGON" = true ]; then
		PrintErrorAndExit "Error: IP $1 is a bogon address, cannot continue"
	elif [ -z "$found_asname" ]; then
		PrintErrorAndExit "Error: IP $1 is not part of an announced prefix, cannot continue"
	fi

	BoxHeader "Recently observed upstream/transit AS for $1"
	# fetch all observed ASPATHs involving this IP address
	full_json_data=$(docurl -s "https://stat.ripe.net/data/bgp-updates/data.json?resource=$1&sourceapp=nitefood-asn")
	found_prefix=$(jq -r '.data.resource' <<<"$full_json_data")
	updates=$(jq '.data.updates[].attrs.path' <<<"$full_json_data")

	GetCAIDARank "$found_asn"

	asnlist=$(jq -r '. as $aspaths | $aspaths[first((range(1;length) | select($aspaths[.] == '"$found_asn"')) - 1)] // empty' <<<"$updates" | sort | uniq -c | sort -rn)
	tot=0
	for line in $asnlist; do
		count=$(awk '{print $1}' <<<"$line")
		tot=$(( tot+count ))
	done
	[ -z "$asnlist" ] && total_upstreams_count=0 || total_upstreams_count=$(wc -l <<<"$asnlist")
	red_upstreams_count=0
	green_upstreams_count=0
	yellow_upstreams_count=0
	white_upstreams_count=0
	dim_upstreams_count=0
	if (( caida_asrank < 100 )) || (( total_upstreams_count > 50 )); then
		# origin AS is in the top 100, therefore less likely to need transits (given its large customer cone),
		# or the prefix is widely announced (likely also by well-connected IXP RS peers).
		# Raise the thresholds to infer transit relationship status (need a higher percentage of BGP updates)
		green_probability=85
		yellow_probability=75
		white_probability=65
	else
		green_probability=66
		yellow_probability=33
		white_probability=25
	fi

	# create a static list of the largest known transit ASNs.
	# The list includes most of the top 35 CAIDA ranked ASNs (https://asrank.caida.org/?page_number=1&page_size=40&sort=rank)
	# Note: the list excludes Hurricane Electric (AS6939) because HE is known to largely reannounce most prefixes it receives
	# (even from IXP RS/SFI peers who do not subscribe a transit relationship with them)
	static_transits_array=( 3356 1299 174 6762 2914 6461 6453 3257 3491 9002 1273 5511 4637 12956 7473 1239 3320 701 7018 6830 7922 )

	legend="\t${red}██ most likely transit\t( very large / Tier 1 upstream AS )${default}"
	legend+="\n\t${green}██ very likely transit\t( >= ${green_probability}% BGP updates from this AS )${default}"
	legend+="\n\t${yellow}██ likely transit\t( >= ${yellow_probability}% BGP updates from this AS )${default}"
	legend+="\n\t██ potentially transit\t( >= ${white_probability}% BGP updates from this AS )${default}"
	legend+="\n\t${dim}██ unlikely transit\t(  < ${white_probability}% BGP updates from this AS )${default}"

	if [ "$JSON_OUTPUT" = false ]; then
		echo -e "\nLegend:\n$legend\n"
		echo -e "${bluebg} Target       : ${default} ${blue}$1${default} ${dim}(matching prefix: ${white}$found_prefix${dim})${default}"
		echo -e "${bluebg} Origin AS    : ${default} ${red}[AS$found_asn] ${green}$found_asname${default}"
		echo -e "${bluebg} CAIDA AS rank: ${default} ${caida_asrank_recap}${default}\n"
	else
		final_json_output=$(jq '. += [{ "prefix": "'"$found_prefix"'", "origin_as": "'"$found_asn"'", "origin_as_name": "'"$found_asname"'", "origin_as_rank": '"$caida_asrank"' }]' <<<"$final_json_output")
		final_json_output=$(jq '.[0] += {"upstreams_count": '"$total_upstreams_count"',"upstreams":[]}' <<<"$final_json_output")
	fi

	for line in $asnlist; do
		is_tier1=false
		count=$(awk '{print $1}' <<<"$line")
		asn=$(awk '{print $2}' <<<"$line")
		asname=$(host -t TXT "AS${asn}.asn.cymru.com" | grep -v "NXDOMAIN" | awk -F'|' 'NR==1{print substr($NF,2,length($NF)-2)}')
		integer_probability=$(( count*100/tot ))
		probability=$(jq -n "$count*100/$tot")
		if grep -qw "$asn" <<<"${static_transits_array[@]}" && (( caida_asrank > 35 )); then
			# static transit list does not apply to most top ASNs (CAIDA ranked < 35).
			# These large networks are more likely to arrange SFI relationships with other Tier-1 networks,
			# rather than pay for transit
			is_tier1=true
			probability_color="${red}"
			(( red_upstreams_count++ ))
		elif (( integer_probability >= "$green_probability" )); then
			probability_color="${green}"
			(( green_upstreams_count++ ))
		elif (( integer_probability >= "$yellow_probability" )); then
			probability_color="${yellow}"
			(( yellow_upstreams_count++ ))
		elif (( integer_probability >= "$white_probability" )); then
			probability_color="${default}"
			(( white_upstreams_count++ ))
		else
			probability_color="${dim}"
			(( dim_upstreams_count++ ))
		fi

		if [ "$JSON_OUTPUT" = true ]; then
			final_json_output=$(jq '.[0].upstreams += [{"asn":"'"$asn"'", "asname":"'"$asname"'", "probability":'"$(printf "%.2f" "$probability")"', "is_tier1":'"$is_tier1"'}]' <<<"$final_json_output")
		else
			printf "${probability_color}██\tAS%-6s (%6.2f%%) - %s${default}\n" "$asn" "$probability" "$asname"
		fi
	done

	# count each type of upstreams and try to determine if this prefix is multihomed
	# echo "dbg green: $green_upstreams_count, yellow: $yellow_upstreams_count, white: $white_upstreams_count, dim: $dim_upstreams_count"
	MULTIPLE_UPSTREAMS=false
	multiple_string="multiple"
	if (( total_upstreams_count >= 20 )); then
		MULTIPLE_UPSTREAMS=true
		multiple_string="several"
	elif (( green_upstreams_count >= 2 )) || (( yellow_upstreams_count >= 2 )) || (( white_upstreams_count >= 2 )) || (( red_upstreams_count >= 2 )); then
		MULTIPLE_UPSTREAMS=true
	fi

	if [ "$JSON_OUTPUT" = false ]; then
		if [ "$MULTIPLE_UPSTREAMS" = true ]; then
			echo -e "\n${bluebg} INFO ${default}${blue} This prefix seems to be reannounced by ${underline}$multiple_string ($total_upstreams_count) upstream ASNs${default}${blue}. Possible reasons include:\n\t- ${underline}BGP multihoming${default}${blue} (if few upstreams announce this prefix)\n\t- ${underline}Tier 1 origin AS${default}${blue} or highly reachable prefix${default}${blue} (if many upstreams announce this prefix)\n\t- ${underline}Anycast prefix${default}\n"
		fi
	else
		json_resultcount="1"
		final_json_output=$(jq '.[0] += {"multiple_upstreams": '"$MULTIPLE_UPSTREAMS"'}' <<<"$final_json_output")
	fi

	if (( total_upstreams_count == 0 )); then
		echo -e "\n${lightgreybg} Prefix has not been observed in the DFZ recently ${default}\n"
	fi
}

AsnServerListener(){

	DisableColors

	BoxHeader "ASN Lookup Server v$ASN_VERSION on $HOSTNAME"

	if [ "$ASN_DEBUG" = true ]; then
		server_user_uid=$(id -u)
		server_user_name=$(id -n -u "$server_user_uid")
		echo -e "\n- ${yellow}[DBG]${default} Server UID       : ${blue}${server_user_uid} (${server_user_name})${default}" >&2
		echo -en "- ${yellow}[DBG]${default} Server BIND_ADDR :" >&2
		[[ -z "$ASN_SRV_BINDADDR" ]] && echo -en " ${green}not specified (default v4/v6)${default}" || echo -en " $ASN_SRV_BINDADDR" >&2
		echo -en "\n- ${yellow}[DBG]${default} Server BIND_PORT : $ASN_SRV_BINDPORT" >&2
		[[ "$ASN_SRV_BINDPORT" = "$DEFAULT_SERVER_BINDPORT" ]] && echo -en " ${green}(default)${default}" >&2
		echo -e "\n- ${yellow}[DBG]${default} Ncat options     : '${blue}${userinput}${default}'\n" >&2
	fi

	CLOUD_SHELL_MARK="${red}❌ NO${default}"

	# fetch external IP and ASN to include in the HTML reports
	StatusbarMessage "Detecting host external IP and ASN"
	WhatIsMyIP
	if [ "$HAVE_IPV6" = true ]; then
		found_asn=$(docurl -s "https://stat.ripe.net/data/whois/data.json?resource=$local_wanip&sourceapp=nitefood-asn" | jq -r '.data.irr_records[0] | map(select(.key | match ("origin"))) | .[].value')
		WhoisASN "$found_asn"
		[[ -z "$ASN_SRV_BINDADDR" ]] && ASN_SRV_BINDADDR="$DEFAULT_SERVER_BINDADDR_v6"
	else
		LookupASNAndRouteFromIP "$local_wanip"
		[[ -z "$ASN_SRV_BINDADDR" ]] && ASN_SRV_BINDADDR="$DEFAULT_SERVER_BINDADDR_v4"
	fi
	if [ -z "$found_asn" ]; then
		found_asn="N/A"
		found_asname="(Unknown)"
	fi
	server_country=$(echo "${found_asname##*,}" | tr -d ' ')
	[[ -z "$server_country" ]] && server_country="(Unknown)"

	# prepare the server URL (for the JS bookmarklet)
	if [ "$ASN_SRV_BINDADDR" = "0.0.0.0" ] || [ "$ASN_SRV_BINDADDR" = "::" ]; then
		INTERNAL_ASNSERVER_ADDRESS="$local_wanip:$ASN_SRV_BINDPORT"
	else
		INTERNAL_ASNSERVER_ADDRESS="$ASN_SRV_BINDADDR:$ASN_SRV_BINDPORT"
	fi
	BOOKMARKLET_URL="http://${INTERNAL_ASNSERVER_ADDRESS}/asn_bookmarklet"
	# detect if we're running in Google Cloud Shell environment
	if [ "$GOOGLE_CLOUD_SHELL" = true ] && [ -n "$WEB_HOST" ]; then
		# on Google Cloud Shell, the $WEB_HOST environment variable contains the external hostname to reach the server
		# the format is https://<port>-<hostname> (cheers https://stackoverflow.com/a/70255668)
		INTERNAL_ASNSERVER_ADDRESS="${ASN_SRV_BINDPORT}-${WEB_HOST}"
		BOOKMARKLET_URL="https://${INTERNAL_ASNSERVER_ADDRESS}/asn_bookmarklet"
		CLOUD_SHELL_MARK="${green}✓ YES${default}"
	fi

	StatusbarMessage

	if [ "$HAVE_IPV6" = true ]; then
		[[ "$IS_HEADLESS" = true ]] && ipv6_mark="YES" || ipv6_mark="${green}✓ YES${default}"
	else
		[[ "$IS_HEADLESS" = true ]] && ipv6_mark="NO" || ipv6_mark="${red}❌ NO${default}"
	fi
	# properly show [IP]:PORT notation in case of IPv6 binding
	if grep -q ':' <<<"$ASN_SRV_BINDADDR"; then
		DISPLAY_ASN_SRV_BINDADDR="[${ASN_SRV_BINDADDR}]"
	else
		DISPLAY_ASN_SRV_BINDADDR="${ASN_SRV_BINDADDR}"
	fi
	echo -e "\n- Server ext. IP  : ${blue}${local_wanip}${default}" \
			"\n- Server Country  : ${blue}${server_country}${default}" \
			"\n- Server ASN      : ${red}[AS${found_asn}]${default} ${green}$found_asname${default}" \
			"\n- Server has IPv6 : ${ipv6_mark}" \
			"\n- Running on GCP  : ${CLOUD_SHELL_MARK}" \
			"\n- Bookmarklet URL : ${BOOKMARKLET_URL}" \
			"\n\n[$(date +"%F %T")] ${bluebg}  INFO   ${default} ASN Lookup Server listening on ${white}${DISPLAY_ASN_SRV_BINDADDR}:${ASN_SRV_BINDPORT}${default}"

	server_country="$(echo -e "$server_country" | tr '[:upper:]' '[:lower:]')"

	trap '
		[[ "$IS_HEADLESS" = false ]] && echo -en "\r" >&2
		echo -e "[$(date +"%F %T")] ${bluebg}  INFO   ${default} ASN Lookup Server requested shutdown, terminating..." >&2
		exit 0
		' INT TERM

	#* Assemble the ncat listener command. Also pass on MONOCHROME/DEBUG preferences
	#* to the listener child (which will output to stderr on server's console)
	#* and print informations about client requests (1 child spawned per client connected)
	read -r -d '' ncat_cmd <<- END_OF_NCAT_CMD
	ncat -k -l $ASN_SRV_BINDADDR $ASN_SRV_BINDPORT $userinput --sh-exec "
				export NCAT_REMOTE_ADDR; \
				found_asn=\"$found_asn\" \
				found_asname=\"$found_asname\" \
			 	server_country=\"$server_country\" \
				INTERNAL_CONNHANDLER_CHILD=false \
			 	INTERNAL_ASNSERVER_CONNHANDLER=true \
				INTERNAL_ASNSERVER_ADDRESS="$INTERNAL_ASNSERVER_ADDRESS" \
			 	MONOCHROME_MODE=\"$MONOCHROME_MODE\" \
			 	ASN_DEBUG=\"$ASN_DEBUG\" \
			 	\"$0\"
		 	"
	END_OF_NCAT_CMD

	#! Start the ncat listener and serve each client request
	#! by respawning the script with $INTERNAL_ASNSERVER_CONNHANDLER => true
	#! for every incoming connection
	eval "$ncat_cmd"

	PrintErrorAndExit "ERROR: The ncat server crashed or couldn't start. Try passing the '-v' option to see precisely what is being passed to it."
}

Ctrl_C() {
	if [ "$NO_ERROR_ON_INTERRUPT" = true ]; then
		StatusbarMessage
		tput sgr0
		ShowMenu
	else
		PrintErrorAndExit "Interrupted"
	fi
}

BoxHeader() { # cheers https://unix.stackexchange.com/a/70616

	# no output if in json mode
	[[ "$JSON_OUTPUT" = true ]] && return
	local message="$*"

	if [ "$IS_ASN_CHILD" = true ]; then
		echo "BOXHEADER $message" # the BOXHEADER tag will be transformed by the ASN server into an html <table> element
	else
		if [ "$IS_HEADLESS" = true ]; then
			echo "// $message //"
		else
			echo -e "\n${white}╭─${message//?/─}─╮\n│ ${yellow}${message}${white} │\n╰─${message//?/─}─╯"
			tput sgr 0
		fi
	fi
}

StatusbarMessage() { # invoke without parameters to delete the status bar message
	# suppress output for headless runs
	[[ "$IS_HEADLESS" = true ]] && return

	if [ "$ASN_DEBUG" = true ]; then
		# [[ -n "$1" ]] && statusdbgstring="$1" || statusdbgstring="[remove last statusbar message]"
		# echo -e "${default}[$(date +'%F %T')] ${lightgreybg}  STATUS ${default} ${statusdbgstring}${default}"
		return
	fi

	if [ -n "$statusbar_message" ]; then
		# delete previous status bar message
		blank_line=$(printf "%.0s " $(seq "$terminal_width"))
		printf "\r%s\r" "$blank_line" >&2
	fi
	if [ -n "$1" ]; then
		statusbar_message="$1"
		max_msg_size=$((terminal_width-23))
		if [ "${#statusbar_message}" -gt "${max_msg_size}" ]; then
			statusbar_message="${lightgreybg}${statusbar_message:0:$max_msg_size}${lightgreybg}..."
		else
			statusbar_message="${lightgreybg}${statusbar_message}"
		fi
		statusbar_message+="${lightgreybg} (press CTRL-C to cancel)...${default}"
		echo -en "$statusbar_message" >&2
	fi
}

WhatIsMyIP() {
	# only lookup local WAN IP once
	[[ -n "$local_wanip" ]] && return
	# retrieve local WAN IP (v6 takes precedence) from ifconfig.co
	local_wanip=$(docurl -s "https://ifconfig.co")
	# handle ifconfig.co serving a captcha-type redirect page (e.g. when coming from some AWS networks)
	grep -qE '^<!DOCTYPE html>' <<<"$local_wanip" && local_wanip=$(docurl -s "https://api64.ipify.org")
	# check if we default to an IPv6 internet connection
	if echo "$local_wanip" | grep -q ':'; then
		HAVE_IPV6=true
	fi
}

DisableColors() {
	# avoid colors for headless server runs (e.g. systemd logs/status),
	# for listener runs, json output and monochrome mode
	if [ "$IS_HEADLESS" = true ] || [ "$JSON_OUTPUT" = true ]; then
		# disable all colors for headless/json
		green=""
		magenta=""
		yellow=""
		white=""
		blue=""
		red=""
		black=""
		lightyellow=""
		lightred=""
		lightblue=""
		lightgreybg=""
		bluebg=""
		redbg=""
		greenbg=""
		yellowbg=""
		dim=""
		default=""
	elif [ "$MONOCHROME_MODE" = true ]; then
		# set all colors to white, leave black/white/dim/default intact
		green="$white"
		magenta="$white"
		yellow="$white"
		blue="$white"
		red="$white"
		lightyellow="$white"
		lightred="$white"
		lightblue="$white"
		bluebg="$lightgreybg"
		redbg="$lightgreybg"
		greenbg="$lightgreybg"
		yellowbg="$lightgreybg"
	fi
}

CoreutilsFixup() {
	# check for GNU coreutils alternatives (improve command predictability on FreeBSD/MacOS systems)
	if [ -x "$(command -v gdate)" ]; then
		date() { gdate "$@"; }
		export -f date
	fi
	if [ -x "$(command -v gsed)" ]; then
		sed() { gsed "$@"; }
		export -f sed
	fi
	if [ -x "$(command -v gawk)" ]; then
		awk() { gawk "$@"; }
		export -f awk
	fi
	if [ -x "$(command -v gbase64)" ]; then
		base64() { gbase64 "$@"; }
		export -f base64
	fi
	if [ -x "$(command -v gwc)" ]; then
		wc() { gwc "$@"; }
		export -f wc
	fi
	if [ "$IS_ASN_CHILD" = true ] || [ "$IS_ASN_CONNHANDLER" = true ]; then
		# suppress the tput command during headless runs
		tput() { :; }
		export -f tput
	fi
}

IpcalcVersionCheck() {
	# check for ipcalc version to accomodate both v1.0.0+ (CentOS/RHEL/Rocky 9) and v0.41+ (Debian derivatives)
	IPCALC_FLAG=""
	if [ "$HAVE_IPCALC" = true ]; then
		ipcalc_version=$(ipcalc -v | sed 's/ipcalc //')
		ipcalc_major=$(echo "$ipcalc_version" | cut -d '.' -f 1)
		case "${ipcalc_major}" in
			"0")
				ipcalc_minor=$(echo "$ipcalc_version" | cut -d '.' -f 2)
				if [ "$ipcalc_minor" -ge 5 ]; then
					IPCALC_FLAG="-r"
				else
					HAVE_IPCALC=false
					missing_tools+="\n - ipcalc"
					disabled_features+="\n - CIDR deaggregation (due to incompatible ipcalc version - v0.5+ for Debian-based or v1.0.0+ for RHEL-based required, but you have v$ipcalc_version)"
				fi
				;;
			"1")
				IPCALC_FLAG="-d"
				;;
		esac
	fi
}

IpcalcDeaggregate() {
	ipcalc_parm=$(tr -d ' ' <<<"$1")
	if grep -q "/" <<<"$1"; then
		# consider input to be already a CIDR block, return it unchanged
		echo "$1"
	else
		ipcalc ${IPCALC_FLAG} "$ipcalc_parm" 2>/dev/null | grep -iv "deaggregate" | awk '{print $NF}' | tail -n1
	fi
}

CheckPrerequisites() {
	saveIFS="$IFS"
	IFS=' '
	prerequisite_tools="jq whois host curl" # mandatory tools
	optional_tools="nmap mtr ipcalc grepcidr ncat aha"	# optional tools
	missing_tools=""
	disabled_features=""
	HARD_FAIL=false

	HAVE_IPCALC=true
	HAVE_NMAP=true
	IXP_DETECTION=true
	UNABLE_TO_SERVE=false

	# BASH version check
	bash_major=$(echo "${BASH_VERSION}" | cut -d '.' -f 1)
	bash_minor=$(echo "${BASH_VERSION}" | cut -d '.' -f 2)
	bash_version_too_low=false
	if [ "$bash_major" -lt 4 ]; then
		bash_version_too_low=true
	elif [ "$bash_major" -eq 4 ] && [ "$bash_minor" -lt 2 ]; then
		bash_version_too_low=true
	fi
	[[ "$bash_version_too_low" = true ]] && PrintErrorAndExit "Error: BASH version must be >= 4.2 (you are running v${BASH_VERSION})"

	# Mandatory tools checking (hard fail if not found)
	for tool in $prerequisite_tools; do
		if [ -z "$(command -v "$tool")" ]; then
			missing_tools+="\n - $tool"
			HARD_FAIL=true
		fi
	done

	# Optional tools checking (no hard fail if not found, but some features disabled)
	for tool in $optional_tools; do
		if [ -z "$(command -v "$tool")" ]; then
			missing_tools+="\n - $tool"
			case "$tool" in
				"mtr")
					disabled_feat="AS path tracing"
					MTR_TRACING=false
					;;
				"nmap")
					disabled_feat="Recon mode (Shodan scanning)"
					HAVE_NMAP=false
					;;
				"ipcalc")
					disabled_feat="CIDR deaggregation"
					HAVE_IPCALC=false
					;;
				"grepcidr")
					disabled_feat="IXP prefix detection"
					IXP_DETECTION=false
					;;
				"ncat"|"aha")
					disabled_feat="ASN Lookup Server"
					UNABLE_TO_SERVE=true
					;;
			esac

			disabled_features+="\n - ${disabled_feat}"
		fi
	done

	IpcalcVersionCheck

	if [ -n "$missing_tools" ]; then
		if [ "$JSON_OUTPUT" = false ]; then
			BoxHeader "! WARNING !"
			echo -e "\nThe following tools were not found on this system:" \
					"${red} ${missing_tools}${default}" >&2

			if [ -n "$disabled_features" ]; then
				echo -e "\nThe following features will be disabled:" \
						"${yellow}${disabled_features}${default}" >&2
			fi

			echo -e "\nPlease install the necessary prerequisite packages\nfor your system by following these instructions:" \
					"\n\n>> ${blue}https://github.com/nitefood/asn#prerequisite-packages${default} <<\n" >&2

			[[ "$HARD_FAIL" = true ]] && PrintErrorAndExit "Can not continue without (at least) the following tools: ${prerequisite_tools// /, }"

			read -srp "${lightgreybg}Press ENTER to continue...${default}" >&2
		else
			[[ "$HARD_FAIL" = true ]] && PrintErrorAndExit "Can not continue without (at least) the following tools: ${prerequisite_tools// /, }"
		fi
	fi

	IQS_TOKEN=""
	# Read ipqualityscore.com token from possible config files on disk
	IFS=$'\n'
	for asn_config_file in $(tr ':' '\n' <<<"$IQS_TOKEN_FILES"); do
		if [ -r "$asn_config_file" ]; then
			IQS_TOKEN=$(tr -d ' \n\r\t' < "$asn_config_file")
			break
		fi
	done
	if [ -z "$IQS_TOKEN" ] && [ "$JSON_OUTPUT" = false ]; then
		# warn the user about the absence of in-depth IP reputation API token
		if [ "$IS_HEADLESS" = true ]; then
			line="------------------------------------------------------------"
			echo -e "\n${line}\nWARNING: No IpQualityScore token found, disabling in-depth\nthreat analysis. Check" \
				"\nhttps://github.com/nitefood/asn#ip-reputation-api-token for\ninstructions on how to enable it." \
				"\n${line}" >&2
		else
			line="────────────────────────────────────────────────────────────"
			echo -en "\n${yellow}${line}\n\t\t\tWARNING${default}" \
				"\n\n${white}No IPQualityScore token found, so disabling in-depth threat" \
				"\nanalysis and IP reputation lookups. Please visit" \
				"\n${blue}https://github.com/nitefood/asn#ip-reputation-api-token${white}" \
				"\nfor instructions on how to enable it." \
				"\n${yellow}${line}${default}\n" >&2
		fi
	fi

	CoreutilsFixup

	IFS="$saveIFS"
}

DebugPrint(){
	# Debug print helper function. will display debug string in terminal mode, or full client debug info in headless mode
	if [ "$ASN_DEBUG" = true ]; then
		# strip CRLFs
		dbgstring=$(echo -e "$1" | tr -d '\r\n')
		if [ "$IS_HEADLESS" = false ]; then
			# command line tool mode
			echo -e "${default}[$(date +'%F %T')] ${lightgreybg}  DEBUG  ${default} $dbgstring" >&2
		else
			# server mode
			if [ -z "$host" ]; then
				target='N/A'
			else
				target="$host"
			fi
			if [ -z "$reqid" ]; then
				requestid='N/A'
			else
				requestid="$reqid"
			fi
			echo -e "${default}[$(date +'%F %T')] ${lightgreybg}  DEBUG  ${default} $dbgstring [CLIENT: ${yellow}$NCAT_REMOTE_ADDR${default}, TARGET: ${magenta}$target${default}, REQID: ${blue}$requestid${default}]" >&2
		fi
	fi
}

StripAnsi() {
	# portable ANSI colors strip helper fn (for termbin sharing) - cheers https://unix.stackexchange.com/a/140255
	# shellcheck disable=SC2001
	echo -e "$1" | sed "s,$(printf '\033')\\[[0-9;]*[a-zA-Z],,g"
}

HandleNcatClientConnection() {

	# ╭─────────────────────────────────────╮
	# │ MAIN NCAT CLIENT CONNECTION HANDLER │
	# ╰─────────────────────────────────────╯

	DisableColors

	# HTTP response headers
	http_ok='HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n'
	http_ok_json='HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n'
	http_ko='HTTP/1.0 400\r\nContent-Type: text/html\r\n\r\n<html><body><h1>400 Bad Request</h1>\nYour request could not be processed.</body></html>'
	http_ko_json='HTTP/1.0 400\r\nContent-Type: application/json\r\n'

	# Javascript bookmarklet
	js_bookmarklet='javascript:(function(){var asnserver="'"${INTERNAL_ASNSERVER_ADDRESS}"'",target=window.location.hostname,'
	js_bookmarklet+='width=screen.width-screen.width/7,height=screen.height-screen.height/4,left=window.innerWidth/2-width/2,top=window.innerHeight/2-height/2;'
	js_bookmarklet+='window.open("http://"+asnserver+"/asn_lookup&"+target,"newWindow","width="+width+",height="+height+",top="+top+",left="+left)})();'

	# HTML bookmarklet page
	read -r -d '' html_bookmarklet_page <<- END_OF_BOOKMARKLET_HTML
	<html>
	<head>
		<meta http-equiv="Content-Type" content="application/xml+xhtml; charset=UTF-8"/>
		<title>[ASN] Server configuration (client-side)</title>
		<style>
			@import url("https://fonts.googleapis.com/css2?family=Roboto+Mono&display=swap");
			html * {
				font-family: "Roboto Mono", monospace;
				font-size: 1em;
				color: $htmlwhite;
				background-color: $htmlblack;
				border-radius: 6px;
			}
		</style>
	</head>
	<body>
	<pre>
		<br /><br />
		<hr>
		<div style="text-align: center;">
			<span style="color:$htmlgreen; font-size: 2em">- ASN Server // Browser Integration -</span>

			<span>1) Drag and drop the <span style="color:$htmlyellow;">yellow</span> link below to your bookmarks toolbar:</span>

			<span style="font-size: 2.5em;"><a style="color:$htmlyellow;" href='$js_bookmarklet' title="ASN Lookup">ASN LOOKUP</a></span>

			<span>2) Close this page and click the new bookmark while viewing any website.
			A lookup and trace for that host should start in a pop-up window.</span>
		<br />
		<hr>
		<span style='color: darkgray; font-style: italic; font-size: 0.8em;'><a href='https://github.com/nitefood/asn' target='_blank'>ASN Lookup Server</a> v${ASN_VERSION} running on $HOSTNAME
		</span>
		</div>
	</pre>
	</body>
	</html>
	END_OF_BOOKMARKLET_HTML

	# HTML opening tags
	# shellcheck disable=SC2016
	html_header='
	<?xml version="1.0" encoding="UTF-8" ?>
	<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
	<html xmlns="http://www.w3.org/1999/xhtml">
		<head>
			<meta http-equiv="Content-Type" content="application/xml+xhtml; charset=UTF-8"/>
			<title>[ASN] Lookup</title>
			<script src="https://ajax.googleapis.com/ajax/libs/jquery/2.2.4/jquery.min.js"></script>
			<script>
				function termbinshare(){
					$("#termbinShareButton").attr("disabled","disabled");
					var oldbuttontext=$("#termbinShareButton").text();
					$("#termbinShareButton").text("Sharing...");
					var tracedata=$("#tracedata").text();
					$.ajax({
						url: "/termbin_share&" + tracedata,
						type: "GET",
						success: function (termbinUrl) {
							termbinUrl = termbinUrl.replace(/(\\r\\n|\\n|\\r)/gm,"");
							var outputcontainer = document.getElementById("share-output-container");
							if (termbinUrl === ""){
								outputcontainer.innerHTML = "<span style=\"color: '"$htmlred"'; font-size: 0.9em;\">Sharing failed, check server console log</span>";
								// show the "sharing output" element
								outputcontainer.classList.remove("hidden");
								// hide it after 3s
								setTimeout(function(){ outputcontainer.classList.add("hidden"); }, 3000);
								$("#termbinShareButton").text(oldbuttontext);
								$("#termbinShareButton").removeAttr("disabled");
							} else {
								$("#share-container").empty();
								$("#share-container").html("<textarea wrap=\"off\" rows=1 cols="+termbinUrl.length+" readonly id=\"termbinoutput\">"+termbinUrl+"</textarea>");
								document.getElementById("termbinoutput").select();
								document.execCommand("copy");
								$("#share-container").html("<a href=\""+termbinUrl+"\" target=\"_blank\" style=\"color: '$htmlblue';\">"+termbinUrl+"</a>");
								outputcontainer.innerHTML = "<span style=\"color: '"$htmlgreen"'; font-size: 1em;\">✓ Link copied to clipboard</span>";
								// show the "sharing output" element
								outputcontainer.classList.remove("hidden");
								// hide it after 3s
								setTimeout(function(){ outputcontainer.classList.add("hidden"); }, 3000);
							}
						}
					});
				}

				// Fade out loader when window is loaded
				$(window).load(function() { $(".loader").fadeOut("fast");; });

			</script>
			<style>
				@import url("https://fonts.googleapis.com/css2?family=Roboto+Mono&display=swap");
				html * {
					font-family: "Roboto Mono", monospace;
					font-size: 1em;
					color:'$htmlwhite';
					background-color: '$htmlblack'; /* background-color: black; */
					border-radius: 6px;
				}
				table {
					border: 1px solid '$htmlyellow';
					margin-left: auto;
					margin-right: auto;
				}
				th { text-align: center; background-color: '$htmlblue'; color: black; }
				td { text-align: center; color: '$htmlwhite'; width: 20%; }
				.center { margin-left: auto; margin-right: auto; }
				.textoutput {
					opacity:1;
					transition:opacity 200ms;
					font-size: 0.8em;
				}
				.hidden {
					opacity: 0;
				}
				/* cheers https://css-tricks.com/snippets/css/make-pre-text-wrap/ */
				pre {
					white-space: pre-wrap;       /* css-3 */
					white-space: -moz-pre-wrap;  /* Mozilla, since 1999 */
					white-space: -pre-wrap;      /* Opera 4-6 */
					white-space: -o-pre-wrap;    /* Opera 7 */
					word-wrap: break-word;       /* Internet Explorer 5.5+ */
				}
				button.sharebutton {
					background-color:'$htmlgreen';
					border: solid 2px '$htmlblack';
					border-radius: 8px;
					display:inline-block;
					cursor:pointer;
					color: black;
					//padding:13px 32px;
					text-decoration:none;
				}
				.sharebutton:hover {
					border: solid 2px '$htmlyellow';
				}
				.sharebutton:active {
					position:relative;
					top:1px;
				}

				/* ------------------------------------------------------------------------*/
				/* CSS For modal popup (whois results in server mode for hostname targets) */
				/* ------------------------------------------------------------------------*/
				/* The Modal (background) */
				.modal {
					display: none; /* Hidden by default */
					position: fixed; /* Stay in place */
					z-index: 1; /* Sit on top */
					left: 0;
					top: 0;
					width: 100%; /* Full width */
					height: 100%; /* Full height */
					overflow: auto; /* Enable scroll if needed */
					background-color: rgb(0,0,0); /* Fallback color */
					background-color: rgba(0,0,0,0.4); /* Black w/ opacity */
				}

				/* Modal Content/Box */
				.modal-content {
					background-color: '$htmlwhite';
					margin: 15% auto; /* 15% from the top and centered */
					font-size: 85%;
					border: 1px solid '$htmlwhite';
					width: 80%; /* Could be more or less, depending on screen size */
				}
				/* The Close Button */
				.close {
					color: #aaa;
					float: right;
					font-size: 28px;
					font-weight: bold;
				}

				.close:hover,
					.close:focus {
						color: black;
						text-decoration: none;
						cursor: pointer;
				}
				.hidden_underline {
					/*text-decoration: none;*/
					text-decoration: underline solid transparent;
					transition: text-decoration 0.2s ease-out;
				}
				.hidden_underline:hover {
					text-decoration: underline solid Currentcolor;
				}
				/* -------------------------------------------------------------------------------*/
				/* CSS Loader - cheers https://www.cssscript.com/demo/beautiful-creative-loaders/ */
				/* modified values to stick to bottom even on scroll:
					position: fixed;
					bottom: 0;
					left: 50%;
				*/
				.loader {
					width: 12px;
					height: 12px;
					border-radius: 50%;
					display: block;
					margin:15px auto;
					position: fixed;
					bottom: 0;
					left: 50%;
					color: '$htmlyellow';
					box-sizing: border-box;
					animation: animloader 1s linear infinite alternate;
				}
				@keyframes animloader {
					0% {
						box-shadow: -38px -12px ,  -14px 0,  14px 0, 38px 0;
					}
					33% {
						box-shadow: -38px 0px, -14px -12px,  14px 0, 38px 0;
					}
					66% {
						box-shadow: -38px 0px , -14px 0, 14px -12px, 38px 0;
					}
					100% {
						box-shadow: -38px 0 , -14px 0, 14px 0 , 38px -12px;
					}
				}
				/* -------------------------------------------------------------------------------*/
			</style>
		</head>
		<body>
			<span class="loader"></span>
			<pre>
	'

	# HTML closing tags
	html_footer='
		</body>
		<script>window.scrollTo(0,document.body.scrollHeight);</script>
	</html>
	'

	CoreutilsFixup

	# a client just connected
	echo -e "[$(date +'%F %T')] ${bluebg}  INFO   ${default} Incoming connection by client ${yellow}$NCAT_REMOTE_ADDR${default}" >&2

	# read input from client (URL being accessed through the client browser)
	read -r line
	DebugPrint "RECEIVED new client request: '$line'"

	# handle 'asn_bookmarklet' command. This will show a web page for easy dragging&dropping of the bookmarklet to the favorites toolbar
	if (echo -e "$line" | grep -Eq "^GET /asn_bookmarklet[?& ]"); then
		DebugPrint "SERVING bookmarklet page to client"
		echo -e "${http_ok}${html_bookmarklet_page}"

	# handle 'termbin_share' command. This will decode the input and send it to termbin, returning a html link to the client
	elif (echo -e "$line" | grep -Eq "^GET /termbin_share&"); then
		# send HTTP 200 OK header to client
		echo -e "${http_ok}"
		# decode input data
		input_data="$(echo -e "$line" | cut -d '&' -f 2- | cut -d ' ' -f 1 | base64 -d | gunzip)"
		termbin_url=""
		if [ -n "$input_data" ]; then
			# share on termbin.com and output the url to the client
			termbin_url="$(echo -e "$input_data" | timeout 10 ncat termbin.com 9999 | tr -d '\r\n\0')" # sanitize trailing characters in termbin output link
		fi
		# analyze the sharing attempt result
		if [ -n "$termbin_url" ]; then
			# sharing successful, output the link
			echo -e "${termbin_url}\n"
			# log the successful sharing attempt
			echo -e "[$(date +'%F %T')] ${greenbg} SHAREOK ${default} Successfully shared termbin link ${blue}${termbin_url}${default} with client ${yellow}$NCAT_REMOTE_ADDR${default}" >&2
			exit 0
		elif [ -z "$input_data" ]; then
			sharefailreason="invalid input data"
		elif [ -z "$termbin_url" ]; then
			sharefailreason="termbin.com error"
		else
			sharefailreason="unknown reason"
		fi
		# log the failed sharing attempt
		echo -e "[$(date +'%F %T')] ${redbg} SHAREKO ${default} Error sharing termbin link with client ${yellow}$NCAT_REMOTE_ADDR${default} ($sharefailreason)" >&2
		# close the client connection without any output
		exit 1

	elif (grep -Eq "^GET /asn_lookup(_json[p]?)?&" <<<"$line"); then
		OUTPUT_TYPE=""
		starttime=$(date +'%s')
		startdatetime=$(date +'%F %T')
		reportdatetime=$(date +'%F %T (%Z)')

		# detect output method requested by the user
		method=$(echo -e "$line" | cut -d '&' -f 1)
		if grep -q "jsonp" <<<"$method"; then
			# user requested pretty-print json output from the server
			OUTPUT_TYPE="jsonp"
		elif grep -q "json" <<<"$method"; then
			# user requested compact json output from the server
			OUTPUT_TYPE="json"
		fi
		# handle 'asn_lookup' command. This will start a lookup for the target.
		# 1) trim down target length to at most 100 characters
		# 2) extract target from client request (cut on ampersand first, space next, e.g.: 'GET /asn_lookup&google.com HTTP/1.1' should return google.com)
		# 3) convert any '%3A' to ':' (for IPv6 searches)
		# 4) convert any '%2F' to '/' (for URL searches)
		# 5) strip leading slash (/google.com -> google.com)
		# 6) sanitize by stripping any character except letters, numbers, and dot/colon/dash [.:-])
		target=$(echo -e "$line" | cut -d '&' -f 2- | awk -F' ' '{print substr($1,0,100)}')
		host=$(echo -e "$target" | sed -e 's/%3[aA]/:/g' -e 's/%2[fF]/\//g' -e 's/^\///' -e 's/[^0-9a-zA-Z/\.:-]//g')

		# validate target by checking if it's an:
		# 1) IP address
		# 2) hostname (beginning with any alphanumeric character and including at least one dot '.')
		# 3) AS number (with or without case-insensitive 'AS' prefix)
		is_valid_target=$(echo -e "$host" | grep -Eo "$ipv4v6regex|^([0-9a-zA-Z])+.*\.|^([aA][sS])?[0-9]{1,6}$")

		# avoid invalid/malformed targets
		if [ -n "$is_valid_target" ]; then
			# this is a valid client request, set up request identifier
			reqid=$(date +'%N')

			echo -e "[$startdatetime] ${yellowbg} STARTED ${default} Lookup request by client ${yellow}$NCAT_REMOTE_ADDR${default} for target ${magenta}$host${default} (Request ID: ${blue}$reqid${default})" >&2

			if [ "$OUTPUT_TYPE" = "json" ] || [ "$OUTPUT_TYPE" = "jsonp" ]; then
				# send HTTP 200 OK response with JSON Content-Type
				echo -e "${http_ok_json}"
			else
				# send HTTP 200 OK response and display HTML headers
				echo -e "${http_ok}${html_header}"
			fi
			countryname=$(docurl -m2 -s "https://restcountries.com/v3.1/alpha/$server_country" | jq -r '.[].name.common')
			if [ -n "$countryname" ] && [ "$countryname" != "null" ]; then
				title_tag="title='$countryname'"
			else
				title_tag=""
			fi

			if [ -z "$OUTPUT_TYPE" ]; then
				# default HTML mode, display ASN server info table
				echo -e "
					<table style='border: none; white-space: nowrap';>
						<tr>
							<th colspan='5' style='background-color: $htmllightgray;'>ASN Lookup Server Report</th>
						</tr>
						<tr>
							<th>Lookup Target</td>
							<th>Client IP</td>
							<th>Lookup Server ASN</td>
							<th>Lookup Server Hostname</td>
							<th>Date and time</td>
						</tr>
						<tr>
							<td style='color:$htmlred;'>$host</td>
							<td style='color:$htmlyellow;'>$NCAT_REMOTE_ADDR</td>
							<td style='color:$htmlgreen;'><a href=\"/asn_lookup&AS$found_asn\" style=\"color: $htmlgreen;\">$found_asn</a> ($found_asname
							<img src='https://cdnjs.cloudflare.com/ajax/libs/flag-icon-css/3.5.0/flags/4x3/$server_country.svg' $title_tag style='height:1.05em; border-radius: 0; vertical-align: middle;'>)
							</td>
							<td style='color:$htmlmagenta;'>$HOSTNAME</td>
							<td style='color:$htmlwhite;'>$reportdatetime</td>
						</tr>
					</table>
					<hr />
				"
			fi

			# spawn ASN child and output results to the client
			DebugPrint "Spawning child"

			INTERNAL_CONNHANDLER_CHILD=true INTERNAL_ASNSERVER_CONNHANDLER=false INTERNAL_ASNSERVER_OUTPUT_TYPE="$OUTPUT_TYPE" TERM=dumb "$0" "$host" |
			{
				#* ╭──────────────────────────────────────────────╮
				#* │ Main child output parsing loop command group │
				#* ╰──────────────────────────────────────────────╯
				if [ -n "$OUTPUT_TYPE" ]; then
					# JSON/JSONP mode
					while IFS= read -r outputline; do
						echo -e "$outputline"
					done
				else
					# HTML mode
					TextHeader() {
						headerwidth="150"
						padchar="_"
						padding="$(printf '%0.1s' ' '{1..500})"
						printf "%${headerwidth}s\n\n" "" | tr " " "${padchar}"
						printf '%*.*s %s %*.*s\n' 0 "$(((headerwidth-2-${#1})/2))" "$padding" "$1" 0 "$(((headerwidth-1-${#1})/2))" "$padding"
						printf "%${headerwidth}s\n" "" | tr " " "${padchar}"
					}

					# initialize textual trace log variable
					tracedata=""
					while IFS= read -r outputline; do
						# DebugPrint "[$reqid] CHILD OUTPUT: $outputline" "false"
						if echo -e "$outputline" | grep -Eq "^BOXHEADER "; then
							# child instance is displaying a BoxHeader, transform it into a <table>
							message=$(echo -e "$outputline" | cut -d ' ' -f 2-)
							echo -e "<table style='width: 30%; height: 5%;'><tr><th style='background-color: $htmlblack; color: $htmlwhite;'>$message</th></tr></table>\n"
							# append boxheader to tracefile
							# tracedata+="$(BoxHeader "$message")\n"
							tracedata+=$(TextHeader "[ $message ]")
							tracedata+="\n\n"
							if echo -e "$message" | grep -q "Trace to "; then
								echo -e "<script>top.document.title='[IN PROGRESS] Path trace to $host'</script>"
							fi
						elif grep -Eq "#COUNTRYCODE" <<<"$outputline"; then
							# child instance is indicating a country code for the current IP, map it to a SVG and display it on the HTML report
							# alternative URLs for the flag SVGs:
							# JSdelivr CDN: https://cdn.jsdelivr.net/npm/flag-icon-css/flags/4x3/$cc.svg
							# Github Pages: https://lipis.github.io/flag-icon-css/flags/4x3/$cc.svg
							# CloudflareJS: https://cdnjs.cloudflare.com/ajax/libs/flag-icon-css/3.5.0/flags/4x3/$cc.svg
							cc=$(echo -e "$outputline" | awk '{print $NF}')
							# lookup full country name
							countryname=$(docurl -m2 -s "https://restcountries.com/v3.1/alpha/$cc" | jq -r '.[].name.common')
							if [ -n "$countryname" ] && [ "$countryname" != "null" ]; then
								title_tag="title='$countryname'"
							else
								title_tag=""
							fi
							target_flag_img="<img src='https://cdnjs.cloudflare.com/ajax/libs/flag-icon-css/3.5.0/flags/4x3/$cc.svg' $title_tag style='height:1.05em; border-radius: 0; vertical-align: middle;'>"
							outputline=$(echo -e "$outputline" | sed -e 's/#COUNTRYCODE.*//')
							tracedata+="$outputline\n"
							outputline=$(echo -e "$outputline" | tr -d '\r\n' | aha -b -n)
							printf "%s%s\n" "$outputline" "$target_flag_img"
						elif grep -Eq "<a href=" <<<"$outputline"; then
							href_stripped=$(awk '{gsub(/<[^>]*>/,""); print }' <<<"$outputline")
							tracedata+="$href_stripped\n"
							printf "%s\n" "$outputline" | aha -b -n | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/&/g'
						elif grep -Eq "#PERFORMWHOIS" <<<"$outputline"; then
							# child instance is asking us to perform a whois lookup for the target domain
							# and show it to the user in the form of a tooltip
							targetdomain=$(echo -e "$outputline" | awk '{print $NF}')
							targetdomaindata=$(whois -H "$targetdomain" | grep -Ev "^\*")
							hostio_href="<a href=\"https://host.io/$targetdomain\" target=\"_blank\" style=\"color: $htmlyellow; font-style: italic;\">host.io</a>"
							hostio_link=" <span style=\"font-size: 75%; color: $htmlyellow;\">$hostio_href🔗</span>"
							read -r -d '' whoisbutton <<- END_OF_MODAL_HTML
								<!-- Trigger/Open The Modal -->
								<button id="whoisbtn" style="cursor:pointer; background: none!important; border: none; padding: 0!important; text-decoration: underline dotted; font-size: 75%; font-style: italic; color: $htmlyellow;">WHOIS</button>
								<!-- The Modal -->
								<div id="myModal" class="modal">
									<!-- Modal content -->
									<div class="modal-content">
										<span class="close"></span>
										<p style="font-size: 120%; font-style: italic; text-align: center;">Whois information for domain <span style="font-weight: bold; color: $htmlred;">$targetdomain</span><br /><pre>$targetdomaindata</pre></p>
									</div>
								</div>
								<script>
									// Get the modal
									var modal = document.getElementById("myModal");

									// Get the button that opens the modal
									var btn = document.getElementById("whoisbtn");

									// Get the <span> element that closes the modal
									var span = document.getElementsByClassName("close")[0];

									// When the user clicks the button, open the modal
									btn.onclick = function() {
									modal.style.display = "block";
									}

									// When the user clicks on <span> (x), close the modal
									span.onclick = function() {
									modal.style.display = "none";
									}

									// When the user clicks anywhere outside of the modal, close it
									window.onclick = function(event) {
									if (event.target == modal) {
										modal.style.display = "none";
									}
									}
								</script>
							END_OF_MODAL_HTML
							outputline=$(echo -e "$outputline" | sed -e 's/#PERFORMWHOIS.*//')
							tracedata+="${outputline}\n"
							outputline+="(<nobr>$whoisbutton</nobr>•$hostio_link )"
							printf "%s\n" "$outputline" | aha -b -n | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/&/g'
						else
							tracedata+="$outputline\n"
							printf "%s\n" "$outputline" | aha -b -n
						fi
						printf "<script>window.scrollTo(0,document.body.scrollHeight);</script>" # cheers https://stackoverflow.com/a/55471426
					done

					#* Child asn instance finished, finish up the html

					# append text footer to tracedata (will only be displayed when sharing results on termbin)
					footermsg="Report generated by ASN Lookup Server v${ASN_VERSION} (https://github.com/nitefood/asn) on $reportdatetime"
					footermsglen=${#footermsg}
					footerhr=$(printf "%150s" "" | tr " " "_")
					tracedata+="$(printf "%s\n\n%*s\n" "$footerhr" $(((footermsglen+150)/2)) "$footermsg")"

					# print closing headers
					endtime=$(date +%s)
					runtime=$((endtime-starttime))
					echo -e "<div style='text-align: center;'>" \
								"<hr>" \
								"<span style='color: darkgray; font-style: italic; font-size: 0.8em;'>" \
									"Generated by <a href='https://github.com/nitefood/asn' target='_blank'>ASN Lookup Server</a> v${ASN_VERSION} running on $HOSTNAME in ${runtime}s (request ID: $reqid)" \
								"</span>" \
								"<br /><br /><span id='share-container'><button id='termbinShareButton' class='sharebutton' onclick='termbinshare()'>Share Results</button></span>" \
								"<div id='share-output-container' class='textoutput hidden'> </div>" \
								"<a href='#' onclick=\"document.getElementById('help-container').classList.toggle('hidden');return false;\" style='color: darkgray; font-size: 0.7em;'>What is that?</a>" \
								"\n<span id='help-container' class='textoutput hidden' style='color: $htmlgreen;'>This report will be shared on <a href='https://termbin.com' target='_blank'>Termbin</a> (a Pastebin-like sharing service for terminal data).\nTermbin pastes have a lifespan of 1 month.</span>" \
							"</div>" \
							"</pre>"

					# create a hidden div with the gzipped+b64 encoded trace output for optional termbin sharing
					tracedata_encoded="$(StripAnsi "$tracedata" | gzip | base64 -w0)"
					echo -e "<div style='display: none;' id='tracedata'>${tracedata_encoded}</div>"

					echo -e "$html_footer"
				fi
			}
			#  end the ncat client connection for this request ID
			childretval="$?"
			if [ "$childretval" -eq 0 ]; then
				DebugPrint "Child process completed successfully with exit code $?"
				[[ -z "$OUTPUT_TYPE" ]] && echo -e "<script>top.document.title='ASN Lookup for $host completed'</script>"
				# log lookup request completed on server side
				echo -e "[$(date +"%F %T")] ${greenbg}COMPLETED${default} Lookup request by client ${yellow}$NCAT_REMOTE_ADDR${default} for target ${magenta}$host${default} (Request ID: ${blue}$reqid${default})" >&2
			else
				DebugPrint "Child process failed with exit code $childretval (SIG$(kill -l $childretval))"
				echo -e "[$(date +"%F %T")] ${redbg}  FAILED ${default} Lookup request by client ${yellow}$NCAT_REMOTE_ADDR${default} for target ${magenta}$host${default} failed with exit code $childretval (SIG$(kill -l $childretval)) (Request ID: ${blue}$reqid${default})" >&2
			fi
			if [ "$childretval" -eq 141 ]; then
				DebugPrint "Client has gone away?"
			fi
		else
			# send HTTP code 400 Bad Request to client
			if [ "$JSON_OUTPUT" = false ]; then
				echo -e "$http_ko"
			else
				echo -e "$http_ko_json"
				userinput="$host"
				json_resultcount=0
				final_json_output=""
				PrintErrorAndExit "bad request"
			fi
			# log lookup request ignored on server side
			echo -e "[$(date +"%F %T")] ${redbg} IGNORED ${default} Malformed data in request by client ${yellow}$NCAT_REMOTE_ADDR${default} for target ${magenta}$host${default}" >&2
		fi
	else
		# ignore spurious browser requests (e.g. 'GET /favicon.ico') or scans.
		# Log the bad request on server side, sleep for 1 second, and drop the connection
		reqbytes=$(echo -e "$line" | awk -F$'\r\n' '{print substr($1,0,30)}')
		echo -e "[$(date +"%F %T")] ${redbg} IGNORED ${default} Ignored request by client ${yellow}$NCAT_REMOTE_ADDR${default}. Request data (first 30 bytes): ${red}${reqbytes}${default}" >&2
		sleep 1
	fi
}

#! ╭───────────────────────╮
#! │ Main asn script start │
#! ╰───────────────────────╯

IFS=$'\n\t'

# Color scheme
green=$'\e[38;5;035m'
magenta=$'\e[38;5;207m'
yellow=$'\e[38;5;142m'
white=$'\e[38;5;007m'
blue=$'\e[38;5;038m'
red=$'\e[38;5;203m'
black=$'\e[38;5;016m'
lightyellow=$'\e[38;5;220m'
lightred=$'\e[38;5;167m'
lightblue=$'\e[38;5;109m'
lightgreybg=$'\e[48;5;252m'${black}
bluebg=$'\e[48;5;038m'${black}
redbg=$'\e[48;5;210m'${black}
greenbg=$'\e[48;5;035m'${black}
yellowbg=$'\e[48;5;142m'${black}
dim=$'\e[2m'
underline=$'\e[4m'
default=$'\e[0m'

# HTML color codes matching ANSI colors used by the script
htmlwhite="#cccccc"
htmlblack="#1e1e1e"
htmllightgray="#d5d5d5"
htmlred="#ff5f5f"
htmldarkred="#b74d4d"
htmlblue="#00afd7"
htmlyellow="#afaf00"
htmlgreen="#00af5f"
htmldarkgreen="#058505"
htmlmagenta="#ff5fff"

[[ "$TERM" = "dumb" ]] && IS_HEADLESS=true || IS_HEADLESS=false

ipv4v6regex='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|'\
'([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|'\
'([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|'\
':((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|'\
'(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|'\
'1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))' # cheers https://stackoverflow.com/a/17871737

# Get terminal width. If running headless in a child instance (or in server mode) set it to a "sane" value to display appropriate HTML spacing in reports
if [ "$IS_HEADLESS" = true ]; then
	terminal_width=233
else
	terminal_width=$(tput cols)
	trap 'terminal_width=$(tput cols)' SIGWINCH
fi

# Check if this script instance was launched by the ASN server connection handler
if [ "$INTERNAL_CONNHANDLER_CHILD" = true ]; then
	IS_ASN_CHILD=true
else
	IS_ASN_CHILD=false
fi

# Check if this script instance was spawned by the ncat listener
if [ "$INTERNAL_ASNSERVER_CONNHANDLER" = true ]; then
	IS_ASN_CONNHANDLER=true
	HandleNcatClientConnection
	exit 0
else
	IS_ASN_CONNHANDLER=false
fi

# External API token for ipqualityscore.com (IP reputation & threat analisys lookup)
# Files will be parsed in the order they are declared (first path found takes precedence)
IQS_TOKEN_FILES="$HOME/.asn/iqs_token:/etc/asn/iqs_token"

# SIGINT trapping
NO_ERROR_ON_INTERRUPT=false
trap Ctrl_C INT

# PeeringDB list of IXP prefixes
peeringdb_dataset=""
peeringdb_ipv6_dataset=""

# Well known ports list
[[ -r "/etc/services" ]] && WELL_KNOWN_PORTS=$(cat /etc/services) || WELL_KNOWN_PORTS=""

# default options (configurable via $HOME/.asnrc)
MTR_TRACING=true
ADDITIONAL_INETNUM_LOOKUP=true
DETAILED_TRACE=false
MTR_ROUNDS=5
MAX_CONCURRENT_SHODAN_REQUESTS=10
SHODAN_SHOW_TOP_N=5
MONOCHROME_MODE=false
ASN_DEBUG=false
JSON_OUTPUT=false
JSON_PRETTY=false
DEFAULT_SERVER_BINDADDR_v4="127.0.0.1"
DEFAULT_SERVER_BINDADDR_v6="::1"
DEFAULT_SERVER_BINDPORT="49200"
IQS_ALWAYS_QUERY=false
IQS_CUSTOM_SETTINGS="" # e.g. "strictness=1&allow_public_access_points=false" - see https://www.ipqualityscore.com/documentation/proxy-detection/overview -> "Note About Front End IP Lookups"
declare -A PEERINGDB_CACHED_DATASETS
declare -A PEERINGDB_CACHED_IXP_DATA
declare -A CAIDARANK_CACHED_AS_DATA

#*
#* Parse command line options
#*
if [[ $# -lt 1 ]]; then
	PrintUsage
	exit 1
fi

# read optional preferences from "$HOME/.asnrc" (only for non-headless runs)
if [ "$IS_HEADLESS" = false ]; then
	rcfile="/${HOME}/.asnrc"
	if [ -r "$rcfile" ]; then
		# shellcheck disable=SC1090
		. "$rcfile"
	fi
fi

status_json_output="ok"
reason_json_output="success"
json_request_time=$(date "+%Y-%m-%dT%H:%M:%S")
starttime="$(date +%s)"
final_json_output=""
json_target_type="unknown"
json_resultcount=0

# optspec contains:
# - options followed by a colon: parameter is mandatory
# - first colon: disable getopts' own error reporting
# 	in this mode, getopts sets optchar to:
# 	'?' -> unknown option
# 	':' -> missing mandatory parameter to the option
optspec=":hvmljJsgn:t:d:o:a:c:u:"

FORCE_ORGSEARCH=false
SUGGEST_SEARCH=false
SERVER_MODE=false
RECON_MODE=false
COUNTRY_BLOCK_MODE=false
GEOLOCATE_ONLY_MODE=false
BGP_UPSTREAM_MODE=false
OPTIONS_PRESENT=false # will be set to true if getopts enters the loop (detects an option being passed)
while getopts "$optspec" optchar; do {

	GetFullParamsFromCurrentPosition(){
		#
		# Helper function that retrieves all the command line
		# parameters starting from position $OPTIND (current
		# option's argument as being parsed by getopts)
		#
		# 1) first param is set to current option's param (space-separated)
		# 2) then append (if any exist) the following command line params.
		#
		# this allows for invocations such as 'asn -o NAME WITH SPACES'
		# without having to quote NAME WITH SPACES
		# The function requires passing the original $@ as parameter
		# so as to not confuse it with the function's own $@.
		#
		# in the above example, $OPTARG="NAME", $OPTIND="3", ${@:$OPTIND}=array("WITH" "SPACES")
		#
		userinput="$OPTARG"
		for option in "${@:$OPTIND}"; do
			userinput+=" $option"
		done
	}

	userinput=""
	OPTIONS_PRESENT=true
    case "${optchar}" in
		"n")
			MTR_TRACING=false
			ADDITIONAL_INETNUM_LOOKUP=false
			GetFullParamsFromCurrentPosition "$@"
			;;
		"t")
			MTR_TRACING=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"d")
			MTR_TRACING=true
			DETAILED_TRACE=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"o")
			FORCE_ORGSEARCH=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"a")
			SUGGEST_SEARCH=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"s")
			MTR_TRACING=false
			RECON_MODE=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"c")
			COUNTRY_BLOCK_MODE=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"g")
			GEOLOCATE_ONLY_MODE=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"u")
			BGP_UPSTREAM_MODE=true
			GetFullParamsFromCurrentPosition "$@"
			;;
		"m")
			MONOCHROME_MODE=true
			;;
		"j")
			MTR_TRACING=false # json output for mtr traces not implemented yet
			JSON_OUTPUT=true
			# GetFullParamsFromCurrentPosition "$@"
			;;
		"J")
			MTR_TRACING=false # json output for mtr traces not implemented yet
			JSON_OUTPUT=true
			JSON_PRETTY=true
			# GetFullParamsFromCurrentPosition "$@"
			;;
		"l")
			SERVER_MODE=true
			argcount=1
			for option in "${@:$OPTIND}"; do
				# one ore more parameters were passed to -l, check if
				# is an IP, PORT or "IP PORT" pair.
				# pass the rest of the command line as direct
				# ncat arguments.
				# Not passing everything directly (-l has the same
				# functionality in ncat) because asn should have more
				# sensible defaults (i.e. bind to 127.0.0.1 and not
				# 0.0.0.0 by default).

				# handle special case (if invocation was 'asn -l -v <server_opts>' instead of 'asn -v -l <server_opts>')
				[[ "$option" = "-v" ]] && { ASN_DEBUG=true; continue; }

				if [ "$argcount" -eq 1 ]; then
					listen_opt1="$option"
					[[ "${listen_opt1:0:1}" = "-" ]] && { listen_opt1=""; userinput+=" $option"; argcount=99999; } # next lines will be treated as ncat options}

				elif [ "$argcount" -eq 2 ]; then
					listen_opt2="$option"
					[[ "${listen_opt2:0:1}" = "-" ]] && { listen_opt2=""; userinput+=" $option"; argcount=99999; } # next lines will be treated as ncat options}
				else
					userinput+=" $option"
				fi
				(( argcount++ ))
			done
			# analyze the args
			ASN_SRV_BINDADDR=""
			ASN_SRV_BINDPORT=""
			for passedarg in $listen_opt1 $listen_opt2; do
				if grep -Eq ":|\." <<<"$passedarg"; then
					# it's an IP address
					ASN_SRV_BINDADDR="$passedarg"
				else
					# it's a port
					ASN_SRV_BINDPORT="$passedarg"
				fi
			done
			# fallback to default port if none was passed.
			# The rest is already in $userinput, ncat will use it for its own args
			[[ -z "$ASN_SRV_BINDPORT" ]] && ASN_SRV_BINDPORT="$DEFAULT_SERVER_BINDPORT"
			# trim the leading whitespace from ncat options
			userinput="${userinput#' '}"
			# '-l' must be the last option (since it includes optional args), bail the getopts loop
			break
			;;
		"h")
			PrintUsage
			exit 0
			;;
		"v")
			ASN_DEBUG=true
			;;
		*)
			if [ "$OPTERR" = 1 ] && [ -t 0 ]; then
				[[ "$optchar" = "?" ]] && PrintUsage "Error: unknown option '-$OPTARG'"
				[[ "$optchar" = ":" ]] && PrintUsage "Error: option '-$OPTARG' requires an argument"
				exit 1
			fi
			;;
	esac
}
done

if [ -t 0 ] || [ "$IS_HEADLESS" = true ]; then
	# input is from the terminal (or this is a headless instance)
	if [ "$OPTIONS_PRESENT" = false ]; then
		# shellcheck disable=SC2124
		userinput="$@"
	elif [ -z "$userinput" ] && [ "$SERVER_MODE" =  false ]; then
		# an option was passed, but it was not one that requires a param (e.g. -m for monochrome mode)
		# fetch the actual target
		GetFullParamsFromCurrentPosition "$@"
	fi
else
	# script was invoked with input from stdin (e.g. "asn -s < iplist")
	# read IP list from stdin and trim blanks and comments
	userinput=$(cat | grep -Ev '^$|^[ \t]*#')
fi

# trim leading whitespace from userinput
userinput=$(awk '{ sub(/^[ \t]+/, ""); print }' <<<"$userinput")
# trim trailing newline from userinput
userinput=$(echo -en "$userinput")
# check if we still don't have a target
if [ -z "$userinput" ] && [ "$SERVER_MODE" = false ]; then
	PrintUsage "Error: no target specified"
fi

[[ "$MONOCHROME_MODE" = true ]] && DisableColors

# options consistency check:
# enable JSON_OUTPUT if the user has JSON_PRETTY=true in the preferences file
# also explicitly disable tracing if the user forgot to pass "-n"
[[ "$JSON_PRETTY" = true ]] && JSON_OUTPUT=true
[[ "$JSON_OUTPUT" = true ]] && MTR_TRACING=false

#* Check prerequisite and optional tools
CheckPrerequisites

local_wanip=""
HAVE_IPV6=false

if [ "$SERVER_MODE" = true ]; then
	# user passed the "-l" switch
	[[ "$UNABLE_TO_SERVE" = true ]] && PrintErrorAndExit "ERROR: Can not start the listening server. Please install the necessary tools."
	AsnServerListener
fi

# handle output type for child instances
# supported output types: json, jsonp
if [ -n "$INTERNAL_ASNSERVER_OUTPUT_TYPE" ]; then
	MTR_TRACING=false
	case "${INTERNAL_ASNSERVER_OUTPUT_TYPE}" in
		"json")
			JSON_OUTPUT=true
		;;
		"jsonp")
			JSON_OUTPUT=true
			JSON_PRETTY=true
		;;
	esac
fi

if [ "$RECON_MODE" = true ]; then
	# user passed the "-s" switch
	final_json_output="[]"
	[[ "$HAVE_NMAP" = false ]] && PrintErrorAndExit "Nmap is required to use -s, but not available on this system"
	# launch Shodan scan
	ShodanRecon
	if [ "$JSON_OUTPUT" = true ]; then
		json_resultcount=$(jq '. | length' <<<"$shodan_json_output")
		final_json_output="$shodan_json_output"
		PrintJsonOutput
	else
		tput sgr0
	fi
	exit 0
fi

if [ "$GEOLOCATE_ONLY_MODE" = true ]; then
	# user passed the "-g" switch
	final_json_output="[]"
	# launch bulk geolocation lookup
	BulkGeolocate
	if [ "$JSON_OUTPUT" = true ]; then
		json_resultcount=$(jq '. | length' <<<"[$geolocation_json_output]")
		final_json_output="$geolocation_json_output"
		PrintJsonOutput
	else
		tput sgr0
	fi
	exit 0
fi

if [ "$COUNTRY_BLOCK_MODE" = true ]; then
	# user passed the "-c" switch
	# check if user passed a country code (.xx)
	if [ "${userinput::1}" == "." ]; then
		cc=$(echo "$userinput" | cut -d '.' -f 2-)
		restcountries_output=$(docurl -s "https://restcountries.com/v3.1/alpha/$cc")
	else
		# Urlencode the spaces in user's input
		countrystring=${userinput// /%20}
		# Look up the country code
		restcountries_output=$(docurl -s "https://restcountries.com/v3.1/name/${countrystring}")
	fi
	have_results=$(jq 'if type=="array" then true else false end' <<<"$restcountries_output")
	[[ "$have_results" = false ]] && PrintErrorAndExit "No countries matching '$userinput'"
	matches=$(jq -r '. | length' <<<"$restcountries_output")
	if [ "$matches" -gt 1 ]; then
		[[ "$JSON_OUTPUT" = true ]] && PrintErrorAndExit "Multiple countries found, please specify a valid country code"
		echo -e "\n${yellow}Multiple countries found, please specify a valid country code:${default}\n"
		for (( i=0; i<"$matches"; i++ )); do
			formalname=$(jq -r ".[$i] | (.name.official)" <<<"$restcountries_output")
			commonname=$(jq -r ".[$i] | (.name.common)" <<<"$restcountries_output")
			cc=$(jq -r ".[$i] | (.cca2)" <<<"$restcountries_output")
			printf "%-55s : ${green}%s${default} (aka: %s)\n" "$formalname" "$cc" "$commonname"
		done
		echo ""
		tput sgr0
		exit 0
	fi
	cc=$(jq -r 'select(.[].cca2 != null) | .[].cca2' <<<"$restcountries_output" | tr '[:upper:]' '[:lower:]')
	[[ -z "$cc" ]] && PrintErrorAndExit "No country matching '$userinput' found"
	countryname=$(jq -r '.[].name.common' <<<"$restcountries_output")
	population=$(jq -r '.[].population' <<<"$restcountries_output")
	country_ipv4_blocks=$(docurl -s "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/$cc.cidr")
	country_ipv6_blocks=$(docurl -s "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv6/$cc.cidr")
	country_ipv4_blocks_count=$(wc -l <<<"$country_ipv4_blocks")
	country_ipv6_blocks_count=$(wc -l <<<"$country_ipv6_blocks")
	if [ "$country_ipv4_blocks" = "404: Not Found" ]; then
		country_ipv4_blocks=""
		country_ipv4_blocks_count=0
	fi
	if [ "$country_ipv6_blocks" = "404: Not Found" ]; then
		country_ipv6_blocks=""
		country_ipv6_blocks_count=0
	fi
	# calculate total number of IPs allocated to the country
	json_country_ipv4_ip_count=0
	cidrlist=$(echo -e "$country_ipv4_blocks" | sed -e 's/^.*\///g' | sort | uniq -c | sort -nr)
	for cidr in $cidrlist; do
		cidr_total_ips=$(awk '{printf "%d", (2**(32-$2) * $1)}' <<<"$cidr")
		json_country_ipv4_ip_count=$(( json_country_ipv4_ip_count + cidr_total_ips ))
	done
	ips_per_capita=$(awk "BEGIN {printf \"%.2g\", $json_country_ipv4_ip_count/$population}")
	country_ipv4_ip_count=$(printf "%'d" "$json_country_ipv4_ip_count")
	population=$(printf "%'d" "$population")
	if [ "$JSON_OUTPUT" = true ]; then
		json_country_ipv4_blocks=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$country_ipv4_blocks")
		json_country_ipv6_blocks=$(jq -c --slurp --raw-input 'split("\n") | map(select(length > 0))' <<<"$country_ipv6_blocks")
		json_resultcount="1"
		json_target_type="country"
		final_json_output="{\"country_name\":\"$countryname\""
		final_json_output+=",\"country_code\":\"$cc\""
		final_json_output+=",\"ipv4_blocks\":$country_ipv4_blocks_count"
		final_json_output+=",\"ipv4_total_ips\":$json_country_ipv4_ip_count"
		final_json_output+=",\"ipv4_per_capita\":$ips_per_capita"
		final_json_output+=",\"ipv4\":${json_country_ipv4_blocks}"
		final_json_output+=",\"ipv6_blocks\":$country_ipv6_blocks_count"
		final_json_output+=",\"ipv6\":${json_country_ipv6_blocks}"
		final_json_output+="}"
		PrintJsonOutput
	else
		BoxHeader "CIDR blocks allocated to $countryname"
		BoxHeader "IPv4"
		echo -e "$country_ipv4_blocks" | pr -4 -T -W$((terminal_width/2))
		BoxHeader "IPv6"
		echo -e "$country_ipv6_blocks" | pr -4 -T -W$((terminal_width/2))
		BoxHeader "IP Statistics for $countryname (.$cc)"
		echo -e "\n- ${green}$country_ipv4_blocks_count${default} IPv4 blocks found\n- ${yellow}$country_ipv6_blocks_count${default} IPv6 blocks found"
		echo -e "- Population: ${population}\n- Total IPv4 addresses: ${blue}$country_ipv4_ip_count${default}${default} (~${blue}$ips_per_capita${default} IPs per person)"
		BoxHeader "CIDR distribution (IPv4)"
		for cidr in $cidrlist; do
			cidrcount=$(awk '{print $1}' <<<"$cidr")
			cidrsize=$(awk '{print $2}' <<<"$cidr")
			[[ "$cidrcount" = "1" ]] && s="" || s="s"
			printf "%10s x ${magenta}/%s${default} %s\n" "$cidrcount" "$cidrsize" "block$s"
		done
		echo ""
	fi
	exit 0
fi

BoxHeader "ASN lookup for $userinput"

if [ "$FORCE_ORGSEARCH" = true ]; then
	# user passed the "-o" switch
	ORG_FILTER=false
	declare -a orgfilters_array
	declare -a excl_orgfilters_array
	SearchByOrg "$userinput"
	exit 0
fi

if [ "$SUGGEST_SEARCH" = true ]; then
	# user passed the "-s" switch
	RIPESuggestASN "$userinput"
	exit 0
fi

input=$(echo "$userinput" | sed 's/\/.*//g' | grep -Eo "$ipv4v6regex")

if [ -z "$input" ]; then
	# Input is not an IP Address
	if [ "$BGP_UPSTREAM_MODE" = true ]; then
		echo -e "\n${red} Error: the ${blue}'-u'${red} option requires an IPv4 or IPv6 address as input${default}\n"
		exit 1
	fi
	# Check if it is a number (ASN)
	asn=$(echo "$userinput" | sed 's/[a|A][s|S]//g' | grep -E "^[0-9]*$")
	if [ -z "$asn" ]; then
		# Input is not an ASN either. See if it's a hostname (includes at least one dot)
		if echo "$userinput" | grep -q "\."; then
			# filter the input in case it's a URL, extracting relevant hostname/IP data
			userinput=$(awk -F[/:] '{gsub(".*//", ""); gsub(".*:.*@", ""); print $1}' <<<"$userinput")
			# run the IP regex again in case input is an IP(v6) URL (e.g. https://1.2.3.4/) and skip resolution if an IP is found
			ip=$(echo "$userinput" | grep -Eo "$ipv4v6regex")
			if [ -z "$ip" ]; then
				if [ "$IS_ASN_CHILD" = true ] && [ "$JSON_OUTPUT" = false ]; then
					# this instance is an ASN server child (not in JSON mode)
					targetdomain=$(rev <<<"$userinput" | cut -d '.' -f 1,2 | rev)
					echo -e "\n${blue}- Resolving \"$userinput\"... #PERFORMWHOIS $targetdomain\n"
				elif [[ "$JSON_OUTPUT" = false ]]; then
					# normal output
					echo -e -n "\n${blue}- Resolving \"$userinput\"... "
				fi
				json_target_type="hostname"
				ip=$(ResolveHostnameToIPList "$userinput")
				if [ -z "$ip" ]; then
					resolver_error="${red}Error: unable to resolve hostname${default}"
					if [ "$IS_ASN_CHILD" = true ] && [ "$JSON_OUTPUT" = false ]; then
						echo -e "$resolver_error\n"
					elif [ "$IS_ASN_CHILD" = false ] && [ "$JSON_OUTPUT" = false ]; then
						# normal output
						echo -e "${resolver_error}\n\n(Hint: if you wanted to search by organization, try the ${blue}'-o'${default} switch)\n" >&2
					else
						# json output (both ASN child and normal instance)
						PrintErrorAndExit "unable to resolve hostname"
					fi
					exit 1
				fi
			fi
			numips=$(echo "$ip" | wc -l)
			[[ $numips = 1 ]] && s="" || s="es"
			[[ "$JSON_OUTPUT" = false ]] && echo -e "${blue}$numips IP address$s found:${default}\n"
			# grab the longest IP to properly size output padding
			longest=0
			for singleip in $ip; do
				[[ ${#singleip} -gt $longest ]] && longest=${#singleip}
			done
			(( longest++ ))
			# output actual results
			ip_to_trace=""
			WhatIsMyIP
			if [ "$IS_ASN_CHILD" = true ] && [ "$numips" -gt 1 ] && [ "$JSON_OUTPUT" = false ]; then
				# Running headless as an ASN server connhandler child, not in JSON mode, and more than 1 IP detected.
				# Speed up the operation and only process the first appropriate IP (v4/v6)
				if [ "$HAVE_IPV6" = true ] && grep -q ':' <<<"$ip"; then
					ip_to_trace=$(echo "$ip" | grep -m1 ':')
				else
					ip_to_trace=$(echo "$ip" | grep -v -m1 ':')
				fi
				LookupASNAndRouteFromIP "$ip_to_trace"
				WhoisIP "$ip_to_trace"
				PrintReputationAndShodanData "$ip_to_trace"
				echo -e "\n${bluebg} INFO ${default} multiple IP support is ${red}disabled${default} for remote traces. The remaining $((numips-1)) IPs have been ignored:"
				count=1
				for singleip in $(echo "$ip" | grep -v "$ip_to_trace"); do
					ignoredip="<a href=\"/asn_lookup&$singleip\">$singleip</a>"
					if [[ count -lt $((numips-1)) ]]; then
						echo -e "   ├ ${white}${ignoredip}${default}"
					else
						echo -e "   └ ${white}${ignoredip}${default}"
					fi
					((count++))
				done
				echo ""
				TraceASPath "$ip_to_trace"
			else
				for singleip in $ip; do
					if [ -n "$ip_to_trace" ] && [ "$JSON_OUTPUT" = true ]; then
						# add a comma to separate json output in case we hit multiple dns lookup results
						final_json_output+=","
					fi
					LookupASNAndRouteFromIP "$singleip"
					WhoisIP "$singleip"
					PrintReputationAndShodanData "$singleip"
					# save the first IP from the dns lookup result
					[[ -z "$ip_to_trace" ]] && ip_to_trace="$singleip"
				done
				[[ "$JSON_OUTPUT" = true ]] && PrintJsonOutput
				# Check if AS path tracing is requested
				if [ "$MTR_TRACING" = true ]; then
					# In case of multiple IPs (DNS RR), trace the first one.
					# Additionally, if we're on an IPv6 connection, default to
					# tracing to the first resolved IPv6 address (if any)
					if [ "$HAVE_IPV6" = true ]; then
						first_ipv6=$(echo "$ip" | grep -m1 ':')
						[[ -n "$first_ipv6" ]] && ip_to_trace="$first_ipv6"
					fi
					TraceASPath "$ip_to_trace"
				fi
			fi
			if [ "$JSON_OUTPUT" = false ]; then
				tput sgr0
				echo ""
			fi
			exit 0
		else
			# not an IP, not an ASN, not a hostname. Consider it an Organization name
			ORG_FILTER=false
			declare -a orgfilters_array
			declare -a excl_orgfilters_array
			SearchByOrg "$userinput"
		fi
	else
		# Input is an ASN
		json_target_type="asn"
		WhoisASN "$asn"
		if [ -z "$found_asname" ]; then
			PrintErrorAndExit "Error: no data found for AS${asn}"
		fi
		GetCAIDARank "$asn"
		target_asname="$found_asname"
		if [ "$JSON_OUTPUT" = true ]; then
			# JSON output
			GetIXPresence "$asn"
			QueryRipestat "$asn"
			final_json_output+="{"
			final_json_output+="\"asn\":\"${asn}\""
			final_json_output+=",\"asname\":\"${target_asname//\"/\\\"}\""
			final_json_output+=",\"asrank\":${caida_asrank//\"/\\\"}"
			final_json_output+=",\"org\":\"${found_org//\"/\\\"}\""
			final_json_output+=",\"holder\":\"${found_holder//\"/\\\"}\""
			final_json_output+=",\"abuse_contacts\":${json_abuse_contacts}"
			final_json_output+=",\"registration_date\":\"${found_createdate}\""
			final_json_output+=",\"ixp_presence\":$json_ixps"
			# peer count
			if [ -n "$ripestat_routing_data" ]; then
				final_json_output+=",\"prefix_count_v4\":${ripestat_ipv4}"
				final_json_output+=",\"prefix_count_v6\":${ripestat_ipv6}"
				final_json_output+=",\"bgp_peer_count\":${ripestat_bgp}"
			fi
			# peer list
			if [ -n "$ripestat_neighbours_data" ]; then
				final_json_output+=",\"bgp_peers\":{"
				final_json_output+="\"upstream\":$json_upstream_peers"
				final_json_output+=",\"downstream\":$json_downstream_peers"
				final_json_output+=",\"uncertain\":$json_uncertain_peers"
				final_json_output+="}"
			fi
			# announced prefixes
			final_json_output+=",\"announced_prefixes\":$json_ripe_prefixes"
			final_json_output+=",\"inetnums\":{"
			final_json_output+="\"v4\":$json_ipv4_aggregated_inetnums"
			final_json_output+=",\"v6\":$json_ipv6_aggregated_inetnums}"
			final_json_output+=",\"inetnums_announced_by_other_as\":{"
			final_json_output+="\"v4\":[$json_ipv4_other_inetnums]"
			final_json_output+=",\"v6\":[$json_ipv6_other_inetnums]}"
			final_json_output+="}"

			PrintJsonOutput
		else
			# normal output
			echo -en "\n${bluebg} AS Number     ──>${default} ${red}${asn}"
			if [ "$IS_ASN_CHILD" = true ]; then
				ripestat_link="<a href=\"https://stat.ripe.net/AS$asn\" target=\"_blank\" style=\"color: $htmlred; font-style: italic;\">RIPEStat</a>"
				he_link="<a href=\"https://bgp.he.net/AS$asn\" target=\"_blank\" style=\"color: $htmlred; font-style: italic;\">HE.NET</a>"
				bgpview_link="<a href=\"https://bgpview.io/asn/$asn\" target=\"_blank\" style=\"color: $htmlred; font-style: italic;\">BGPView</a>"
				bgptools_link="<a href=\"https://bgp.tools/as/$asn\" target=\"_blank\" style=\"color: $htmlred; font-style: italic;\">BGPTools</a>"
				peeringdb_link="<a href=\"https://www.peeringdb.com/asn/$asn\" target=\"_blank\" style=\"color: $htmlred; font-style: italic;\">PeeringDB</a>"
				echo -en " <span style=\"font-size: 75%; color: $htmlred;\">($ripestat_link🔗 • $he_link🔗 • $bgpview_link🔗 • $bgptools_link🔗 • $peeringdb_link🔗)</span>"
			fi
			echo ""
			echo -en "${bluebg} AS Name       ──>${default} ${green}${target_asname}"
			if [ "$IS_ASN_CHILD" = true ]; then
				# signal to the parent connhandler the correct country flag to display for this ASN
				flag_icon_cc=$(echo "${target_asname##*,}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
				[[ -n "$flag_icon_cc" ]] && echo -n " #COUNTRYCODE $flag_icon_cc"
			fi
			printf "\n"
			echo -e "${bluebg} Organization  ──>${default} ${yellow}${found_holder} (${found_org})"
			echo -e "${bluebg} CAIDA AS Rank ──>${default} ${caida_asrank_recap}${default}"
			echo -e "${bluebg} Abuse contact ──>${default} ${blue}${found_abuse_contact}"
			echo -e "${bluebg} AS Reg. date  ──>${default} ${white}${found_createdate}"
			echo -e "${bluebg} RIR (Region)  ──>${default} ${white}${caida_rir}"
			echo -en "${bluebg} Peering @IXPs ──>${default} "
			GetIXPresence "$asn"
			echo ""
			BoxHeader "BGP informations for AS${asn} (${target_asname})"
			echo ""
			echo -e "${bluebg} BGP Neighbors  ────>${default} ${green}${caida_degree_total}${default} ${dim}(${default}${caida_degree_provider}${dim} Transits • ${default}${caida_degree_peer}${dim} Peers • ${default}${caida_degree_customer}${dim} Customers)${default}"
			echo -e "${bluebg} Customer cone  ────>${default} ${green}${caida_customercone} ${default}${dim}(# of ASNs observed in the customer cone for this AS)${default}"
			echo ""
			BoxHeader "Prefix informations for AS${asn} (${target_asname})"
			echo ""
			QueryRipestat "${asn}"
			if [ -n "$ripestat_routing_data" ]; then
				echo -e "${bluebg} IPv4 Prefixes  ────>${default} ${green}${ripestat_ipv4}"
				echo -e "${bluebg} IPv6 Prefixes  ────>${default} ${yellow}${ripestat_ipv6}"
			fi
			if [ -n "$ripestat_neighbours_data" ]; then
				[[ -n "$upstream_peers" ]] && upstream_peers=$(echo -e "$upstream_peers") || upstream_peers="${redbg} NONE ${default}"
				[[ -n "$downstream_peers" ]] && downstream_peers=$(echo -e "$downstream_peers") || downstream_peers="${redbg} NONE ${default}"
				[[ -n "$uncertain_peers" ]] && uncertain_peers=$(echo -e "$uncertain_peers") || uncertain_peers="${redbg} NONE ${default}"
				echo ""
				BoxHeader "Peering informations for AS${asn} (${target_asname})"
				echo -e "\n${green}──────────────── Upstream Peers ────────────────${default}\n\n${upstream_peers}"
				echo -e "\n${yellow}─────────────── Downstream Peers ───────────────${default}\n\n${downstream_peers}"
				echo -e "\n${white}─────────────── Uncertain  Peers ───────────────${default}\n\n${uncertain_peers}"
			fi
			echo ""
			BoxHeader "Aggregated IP resources for AS${asn} (${target_asname})"
			echo -e "\n${green}───── IPv4 ─────${default}"
			[[ -n "$ipv4_inetnums" ]] && echo -e "${green}${ipv4_inetnums}${default}" || echo -e "\n${redbg} NONE ${default}"
			echo -e "\n${yellow}───── IPv6 ─────${default}"
			[[ -n "$ipv6_inetnums" ]] && echo -e "${yellow}${ipv6_inetnums}${default}" || echo -e "\n${redbg} NONE ${default}"
			tput sgr0
			echo ""
		fi
		exit 0
	fi
else
	# Input is an IP address
	grep -q ":" <<<"$input" && json_target_type="ipv6" || json_target_type="ipv4"
	# Perform IP lookup
	LookupASNAndRouteFromIP "$input"
	(( longest=${#input}+1 ))
	if [ "$BGP_UPSTREAM_MODE" = true ]; then
		BGPUpstreamLookup "$input"
		[[ "$JSON_OUTPUT" = true ]] && PrintJsonOutput
		exit 0
	fi
	WhoisIP "$input"
	PrintReputationAndShodanData "$input"
	[[ "$JSON_OUTPUT" = true ]] && PrintJsonOutput
	# Perform AS path tracing if requested
	[[ "$MTR_TRACING" = true ]] && TraceASPath "$input"
	if [ "$JSON_OUTPUT" = false ]; then
		tput sgr0
		echo ""
	fi
	exit 0
fi
