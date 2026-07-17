# config/initializers/sidekiq.rb

redis_url =
  ENV.fetch(
    "REDIS_URL",
    "redis://127.0.0.1:6379/0"
  )

Sidekiq.configure_server do |config|
  config.redis = {
    url: redis_url
  }

  publish_actor_labels_worker_status = lambda do
    next unless ARGV.any? { |arg| arg.to_s == "actor_labels_strict" }

    ActorLabels::StrictBatchJob.publish_worker_status!
  rescue StandardError => error
    Rails.logger.warn(
      "[sidekiq] actor_labels_worker_status_failed " \
      "#{error.class}: #{error.message}"
    )
  end

  config.on(:startup, &publish_actor_labels_worker_status)
  config.on(:heartbeat, &publish_actor_labels_worker_status)
end

Sidekiq.configure_client do |config|
  config.redis = {
    url: redis_url
  }
end
