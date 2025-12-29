module FeatureRequestsHelper
  def feature_request_status_badge(fr)
    color_classes =
      case fr.status
      when "pending"          then "bg-slate-700 text-slate-100 border-slate-500"
      when "awaiting_payment" then "bg-amber-500/10 text-amber-300 border-amber-400/60"
      when "paid"             then "bg-emerald-500/10 text-emerald-300 border-emerald-400/60"
      when "in_progress"      then "bg-sky-500/10 text-sky-300 border-sky-400/60"
      when "done"             then "bg-violet-500/10 text-violet-300 border-violet-400/60"
      when "rejected"         then "bg-red-500/10 text-red-300 border-red-400/60"
      else                           "bg-slate-700 text-slate-100 border-slate-500"
      end

    content_tag :span,
                fr.status.tr("_", " "),
                class: "inline-flex items-center px-2 py-0.5 rounded-full border text-xs font-medium #{color_classes}"
  end
end
