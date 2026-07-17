# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "json"

module ActorBehaviors
  module Heavy
    module Service
      class BuildFromEvidence
        HEAVY_VERSION =
          Contract::HEAVY_VERSION

        ANALYSIS_KIND =
          Contract::ANALYSIS_KIND

        def self.call(
          source_cluster_id:,
          window_from_height:,
          window_to_height:,
          profile_evidence:,
          distribution_evidence:,
          provenance:
        )
          new(
            source_cluster_id:
              source_cluster_id,

            window_from_height:
              window_from_height,

            window_to_height:
              window_to_height,

            profile_evidence:
              profile_evidence,

            distribution_evidence:
              distribution_evidence,

            provenance:
              provenance
          ).call
        end

        def initialize(
          source_cluster_id:,
          window_from_height:,
          window_to_height:,
          profile_evidence:,
          distribution_evidence:,
          provenance:
        )
          @source_cluster_id =
            source_cluster_id.to_i

          @window_from_height =
            window_from_height.to_i

          @window_to_height =
            window_to_height.to_i

          @profile_evidence =
            profile_evidence.to_h

          @distribution_evidence =
            distribution_evidence.to_h

          @provenance =
            provenance.to_h
        end

        def call
          strict_snapshot =
            ActorBehaviorSnapshot.find_by(
              cluster_id:
                source_cluster_id,

              status:
                "certified"
            )

          unless strict_snapshot
            return deferred_result(
              :strict_behavior_snapshot_missing
            )
          end

          profile =
            strict_snapshot.actor_profile

          unless profile
            return deferred_result(
              :actor_profile_missing
            )
          end

          mismatch_reason =
            evidence_mismatch_reason(
              strict_snapshot:
                strict_snapshot
            )

          if mismatch_reason
            return deferred_result(
              mismatch_reason
            )
          end

          score_result =
            InfrastructureScore.call(
              profile_evidence:
                profile_evidence,

              distribution_evidence:
                distribution_evidence
            )

          evidence = {
            analysis_kind:
              ANALYSIS_KIND,

            source_cluster_id:
              source_cluster_id,

            window: {
              from_height:
                window_from_height,

              to_height:
                window_to_height
            },

            profile:
              profile_evidence,

            direct_distribution:
              distribution_evidence,

            score_evidence:
              score_result
                .fetch(:evidence)
                .merge(
                  version:
                    score_result.fetch(:version),

                  mode:
                    score_result.fetch(:mode),

                  decision:
                    score_result.fetch(:decision)
                ),

            provenance:
              provenance
          }

          fingerprint =
            evidence_fingerprint(
              evidence
            )

          result = nil

          ActorBehaviorHeavySnapshot.transaction do
            snapshot =
              ActorBehaviorHeavySnapshot
                .lock
                .find_or_initialize_by(
                  cluster_id:
                    source_cluster_id,

                  analysis_kind:
                    ANALYSIS_KIND
                )

            created =
              snapshot.new_record?

            if !created &&
               current_snapshot?(
                 snapshot:
                   snapshot,

                 strict_snapshot:
                   strict_snapshot,

                 fingerprint:
                   fingerprint
               )
              result =
                success_result(
                  snapshot:
                    snapshot,

                  score_result:
                    score_result,

                  created:
                    false,

                  updated:
                    false,

                  unchanged:
                    true
                )

              next
            end

            snapshot.assign_attributes(
              actor_profile_id:
                profile.id,

              actor_behavior_snapshot_id:
                strict_snapshot.id,

              downstream_cluster_id:
                nil,

              analysis_kind:
                ANALYSIS_KIND,

              heavy_version:
                HEAVY_VERSION,

              status:
                "certified",

              source_profile_fingerprint:
                strict_snapshot.profile_fingerprint,

              source_profile_height:
                strict_snapshot.profile_height,

              source_cluster_composition_version:
                strict_snapshot
                  .cluster_composition_version,

              source_behavior_version:
                strict_snapshot.behavior_version,

              window_from_height:
                window_from_height,

              window_to_height:
                window_to_height,

              signals:
                score_result.fetch(:signals),

              scores:
                score_result.fetch(:scores),

              evidence:
                evidence,

              evidence_fingerprint:
                fingerprint,

              computed_at:
                Time.current,

              error_code:
                nil,

              error_message:
                nil
            )

            snapshot.save!

            result =
              success_result(
                snapshot:
                  snapshot,

                score_result:
                  score_result,

                created:
                  created,

                updated:
                  !created,

                unchanged:
                  false
              )
          end

          result
        rescue StandardError => error
          {
            ok: false,
            status: "failed",
            reason: :calculation_failed,

            source_cluster_id:
              source_cluster_id,

            analysis_kind:
              ANALYSIS_KIND,

            error_class:
              error.class.name,

            error_message:
              error.message,

            created: false,
            updated: false,
            unchanged: false
          }
        end

        private

        attr_reader(
          :source_cluster_id,
          :window_from_height,
          :window_to_height,
          :profile_evidence,
          :distribution_evidence,
          :provenance
        )

        def evidence_mismatch_reason(
          strict_snapshot:
        )
          profile_cluster_id =
            evidence_value(
              profile_evidence,
              :cluster_id
            )

          if profile_cluster_id.present? &&
             profile_cluster_id.to_i !=
               source_cluster_id
            return :profile_cluster_mismatch
          end

          profile_id =
            evidence_value(
              profile_evidence,
              :actor_profile_id
            )

          if profile_id.present? &&
             profile_id.to_i !=
               strict_snapshot.actor_profile_id
            return :actor_profile_mismatch
          end

          distribution_cluster_id =
            evidence_value(
              distribution_evidence,
              :cluster_id
            )

          if distribution_cluster_id.present? &&
             distribution_cluster_id.to_i !=
               source_cluster_id
            return :distribution_cluster_mismatch
          end

          nil
        end

        def evidence_value(
          evidence,
          key
        )
          evidence[key] ||
            evidence[key.to_s]
        end

        def current_snapshot?(
          snapshot:,
          strict_snapshot:,
          fingerprint:
        )
          snapshot.status ==
            "certified" &&
            snapshot.analysis_kind ==
              ANALYSIS_KIND &&
            snapshot.heavy_version ==
              HEAVY_VERSION &&
            snapshot.downstream_cluster_id.nil? &&
            snapshot.actor_behavior_snapshot_id ==
              strict_snapshot.id &&
            snapshot.source_profile_fingerprint ==
              strict_snapshot.profile_fingerprint &&
            snapshot.source_profile_height ==
              strict_snapshot.profile_height &&
            snapshot.source_cluster_composition_version ==
              strict_snapshot
                .cluster_composition_version &&
            snapshot.source_behavior_version ==
              strict_snapshot.behavior_version &&
            snapshot.window_from_height ==
              window_from_height &&
            snapshot.window_to_height ==
              window_to_height &&
            snapshot.evidence_fingerprint ==
              fingerprint
        end

        def success_result(
          snapshot:,
          score_result:,
          created:,
          updated:,
          unchanged:
        )
          {
            ok: true,

            status:
              snapshot.status,

            decision:
              score_result.fetch(:decision),

            snapshot_id:
              snapshot.id,

            source_cluster_id:
              snapshot.cluster_id,

            downstream_cluster_id:
              snapshot.downstream_cluster_id,

            analysis_kind:
              snapshot.analysis_kind,

            heavy_version:
              snapshot.heavy_version,

            scores:
              snapshot.scores,

            signals:
              snapshot.signals,

            created:
              created,

            updated:
              updated,

            unchanged:
              unchanged,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          }
        end

        def deferred_result(reason)
          {
            ok: true,
            status: "deferred",
            reason:
              reason,

            source_cluster_id:
              source_cluster_id,

            downstream_cluster_id:
              nil,

            analysis_kind:
              ANALYSIS_KIND,

            created: false,
            updated: false,
            unchanged: false,

            label_sync: {
              status: "skipped",
              reason: :shadow_mode
            }
          }
        end

        def evidence_fingerprint(value)
          Digest::SHA256.hexdigest(
            JSON.generate(
              canonical_value(
                fingerprint_payload(
                  value
                )
              )
            )
          )
        end

        # Les durées dépendent de la charge, du cache et du matériel.
        # Elles restent enregistrées pour l'observabilité, mais ne
        # doivent pas provoquer une réécriture du snapshot métier.
        def fingerprint_payload(value)
          payload =
            value.deep_dup

          direct_distribution =
            evidence_value(
              payload,
              :direct_distribution
            )

          metrics =
            evidence_value(
              direct_distribution || {},
              :metrics
            )

          if metrics.respond_to?(:delete)
            metrics.delete(
              :stage_durations_seconds
            )

            metrics.delete(
              "stage_durations_seconds"
            )
          end

          payload
        end

        def canonical_value(value)
          case value
          when Hash
            value
              .map do |key, child|
                [
                  key.to_s,
                  canonical_value(child)
                ]
              end
              .sort_by(&:first)
              .to_h

          when Array
            value.map do |child|
              canonical_value(child)
            end

          when BigDecimal
            value.to_s("F")

          when Time, DateTime
            value.iso8601(6)

          else
            value
          end
        end
      end
    end
  end
end
