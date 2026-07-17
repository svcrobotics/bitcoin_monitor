# frozen_string_literal: true

require "test_helper"

class SystemAnomalyNotificationTest < ActionView::TestCase
  test "renders an empty turbo stream target when notification is absent" do
    render(
      partial: "system/anomaly_notification",
      locals: {
        notification: nil
      }
    )

    assert_select(
      "#system_anomaly_notification"
    )

    assert_select(
      "#system_anomaly_notification[data-controller]",
      count: 0
    )

    assert_no_match(/Alerte/, rendered)
    assert_no_match(/Système rétabli/, rendered)
  end

  test "renders a persistent warning with a close button" do
    render(
      partial: "system/anomaly_notification",
      locals: {
        notification: {
          severity: "warning",
          transition: "new",
          message: "ActorProfile ne progresse plus."
        }
      }
    )

    assert_select(
      "#system_anomaly_notification[aria-live='polite']"
    )

    assert_select(
      "#system_anomaly_notification[data-controller='anomaly-notification']"
    )

    assert_select(
      "#system_anomaly_notification[data-anomaly-notification-auto-dismiss-value='false']"
    )

    assert_includes rendered, "Alerte"
    assert_includes rendered, "ActorProfile ne progresse plus."
    assert_includes rendered, "Fermer"

    refute_includes rendered, "Système rétabli"
    refute_includes rendered, "disparaîtra automatiquement"
  end

  test "renders a persistent critical alert" do
    render(
      partial: "system/anomaly_notification",
      locals: {
        notification: {
          severity: "critical",
          transition: "new",
          message: "Layer1 a un retard critique."
        }
      }
    )

    assert_select "[role='alert']"

    assert_select(
      "#system_anomaly_notification[data-anomaly-notification-auto-dismiss-value='false']"
    )

    assert_includes rendered, "Alerte critique"
    assert_includes rendered, "Layer1 a un retard critique."
  end

  test "renders a resolved event as an auto dismissing system toast" do
    render(
      partial: "system/anomaly_notification",
      locals: {
        notification: {
          severity: "warning",
          transition: "resolved",
          message: "ActorBehavior progresse de nouveau."
        }
      }
    )

    assert_select "[role='status']"

    assert_select(
      "#system_anomaly_notification[data-anomaly-notification-auto-dismiss-value='true']"
    )

    assert_select(
      "#system_anomaly_notification[data-anomaly-notification-delay-value='6000']"
    )

    assert_includes rendered, "Système rétabli"
    assert_includes rendered, "ActorBehavior progresse de nouveau."
    assert_includes rendered, "disparaîtra automatiquement"

    refute_includes rendered, ">Résolution<"
  end

  test "positions the notification outside the module content" do
    render(
      partial: "system/anomaly_notification",
      locals: {
        notification: {
          severity: "warning",
          transition: "new",
          message: "Test"
        }
      }
    )

    assert_select(
      "#system_anomaly_notification.fixed[style*='right: 1.25rem'][style*='bottom: 1.25rem'][style*='z-index: 100'][style*='pointer-events: auto']"
    )

    assert_select(
      "button[data-action='click->anomaly-notification#dismiss'][style*='pointer-events: auto']"
    )
  end
end
