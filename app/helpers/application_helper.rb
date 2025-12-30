module ApplicationHelper
	def info_bulle(text)
	  content_tag :span,
	              "ⓘ",
	              class: "ml-1 align-middle text-blue-400 hover:text-blue-200 text-xs font-bold cursor-help",
	              title: text
	end

	def mempool_size_badge(bytes)
	  mem_mb = bytes.to_f / 1_000_000.0

	  # Définition de l'icône + couleur
	  if mem_mb < 5
	    icon = "🟢"
	    color_class = "text-green-300"
	  elsif mem_mb < 30
	    icon = "🟡"
	    color_class = "text-yellow-300"
	  else
	    icon = "🔴"
	    color_class = "text-red-400"
	  end

	  # Exemple : "🟢 0.19 MB"
	  label = "#{icon} #{mem_mb.round(2)} MB"

	  content_tag :span, label, class: "font-semibold #{color_class}"
	end

	def mempool_minfee_badge(sat_vb)
	  # Définir les seuils
	  if sat_vb < 5
	    icon = "🟢"
	    color_class = "text-green-300"
	  elsif sat_vb < 30
	    icon = "🟡"
	    color_class = "text-yellow-300"
	  else
	    icon = "🔴"
	    color_class = "text-red-400"
	  end

	  label = "#{icon} #{sat_vb} sat/vB"

	  content_tag :span, label, class: "font-semibold #{color_class}"
	end

	def network_name(raw)
	  case raw.to_s
	  when "main"     then "Mainnet"
	  when "test"     then "Testnet"
	  when "regtest"  then "Regtest"
	  else raw
	  end
	end

	def btc(amount)
	  return "0.00" if amount.nil?
	  sprintf("%.2f BTC", amount.to_d)
	end

	def format_sats(sats)
	  return "0" if sats.nil?
	  sats.to_i.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse # 12 345
	end

	def format_btc_amount(amount)
	  return "0.00" if amount.nil?
	  sprintf("%.2f", amount.to_d)
	end

	def btc_raw(amount)
      amount.to_d.to_s("F")
    end
end
