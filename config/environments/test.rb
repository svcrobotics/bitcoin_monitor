# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

require "uri"

module TestRedisConfiguration
  DEFAULT_URL = "redis://127.0.0.1:6379/15"
  DB_ZERO_ERROR =
    "Unsafe Redis configuration: RAILS_ENV=test cannot use Redis DB 0"
  INVALID_URL_ERROR =
    "Unsafe Redis configuration: RAILS_ENV=test requires a valid redis " \
    "or rediss URL with an explicit non-zero database number"

  module_function

  def resolve(environment = ENV)
    configured_url = environment["TEST_REDIS_URL"]
    candidate =
      if configured_url.nil? || configured_url.empty?
        DEFAULT_URL
      else
        configured_url
      end

    validate!(candidate)
  end

  def validate!(candidate)
    uri = URI.parse(candidate)

    raise ArgumentError, INVALID_URL_ERROR unless %w[redis rediss].include?(uri.scheme)

    database_match = %r{\A/(\d+)\z}.match(uri.path.to_s)
    raise ArgumentError, INVALID_URL_ERROR unless database_match

    database = Integer(database_match[1], 10)
    raise ArgumentError, DB_ZERO_ERROR if database.zero?

    candidate
  rescue URI::InvalidURIError, TypeError
    raise ArgumentError, INVALID_URL_ERROR
  end
end

ENV["REDIS_URL"] = TestRedisConfiguration.resolve

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
