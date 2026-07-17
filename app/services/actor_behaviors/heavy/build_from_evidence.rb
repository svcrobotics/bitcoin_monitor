# frozen_string_literal: true

require "digest"
require "json"

module ActorBehaviors
  module Heavy
    class BuildFromEvidence
      HEAVY_VERSION =
        "exchange_infrastructure_heavy_v2"

      ANALYSIS_KIND =
        "exchange_infrastructure"

      def self.call(
        source_cluster_id:,
        downstream_cluster_id:,
        window_from_height:,
        window_to_height:,
        deposit_evidence:,
        sweep_evidence:,
        distribution_evidence:,
        provenance:
      )
        new(
          source_cluster_id:
            source_cluster_id,

          downstream_cluster_id:
            downstream_cluster_id,

          window_from_height:
            window_from_height,

          window_to_height:
            window_to_height,

          deposit_evidence:
            deposit_evidence,

          sweep_evidence:
            sweep_evidence,

          distribution_evidence:
            distribution_evidence,

          provenance:
            provenance
        ).call
      end

      def initialize(
        source_cluster_id:,
        downstream_cluster_id:,
        window_from_height:,
        window_to_height:,
        deposit_evidence:,
        sweep_evidence:,
        distribution_evidence:,
        provenance:
      )
        @source_cluster_id =
          source_cluster_id.to_i

        @downstream_cluster_id =
          downstream_cluster_id.to_i

        @window_from_height =
          window_from_height.to_i

        @window_to_height =
          window_to_height.to_i

        @deposit_evidence =
          deposit_evidence.to_h

        @sweep_evidence =
          sweep_evidence.to_h

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

        downstream_cluster =
          Cluster.find_by(
            id:
              downstream_cluster_id
          )

        unless downstream_cluster
          return deferred_result(
            :downstream_cluster_missing
          )
        end

        observed_destination =
          sweep_evidence[
            :top_destination_cluster_id
          ] ||
          sweep_evidence[
            "top_destination_cluster_id"
          ]

        if observed_destination.to_i !=
           downstream_cluster_id
          return deferred_result(
            :downstream_cluster_mismatch
          )
        end

        score_result =
          ExchangeInfrastructureScore.call(
            deposit_evidence:
              deposit_evidence,

            sweep_evidence:
              sweep_evidence,

            distribution_evidence:
              distribution_evidence
          )

        evidence =
          {
            source_cluster_id:
              source_cluster_id,

            downstream_cluster_id:
              downstream_cluster_id,

            window: {
              from_height:
                window_from_height,

              to_height:
                window_to_height
            },

            deposit:
              deposit_evidence,

            sweep:
              sweep_evidence,

            downstream_distribution:
              distribution_evidence,

            score_evidence:
              score_result
                .fetch(:evidence)
                .merge(
                  version:
                    score_result.fetch(:version)
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
              downstream_cluster.id,

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
              score_result.fetch(
                :signals
              ),

            scores:
              score_result.fetch(
                :scores
              ),

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
          error_class: error.class.name,
          error_message: error.message
        }
      end

      private

      attr_reader(
        :source_cluster_id,
        :downstream_cluster_id,
        :window_from_height,
        :window_to_height,
        :deposit_evidence,
        :sweep_evidence,
        :distribution_evidence,
        :provenance
      )

      def current_snapshot?(
        snapshot:,
        strict_snapshot:,
        fingerprint:
      )
        snapshot.status == "certified" &&
          snapshot.heavy_version ==
            HEAVY_VERSION &&
          snapshot.downstream_cluster_id ==
            downstream_cluster_id &&
          snapshot.source_profile_fingerprint ==
            strict_snapshot.profile_fingerprint &&
          snapshot.window_from_height ==
            window_from_height &&
          snapshot.window_to_height ==
            window_to_height &&
          snapshot.evidence_fingerprint ==
            fingerprint
      end

      def success_result(
        snapshot:,
        created:,
        updated:,
        unchanged:
      )
        {
          ok: true,
          status: snapshot.status,
          snapshot_id: snapshot.id,
          source_cluster_id:
            snapshot.cluster_id,
          downstream_cluster_id:
            snapshot.downstream_cluster_id,
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
            unchanged
        }
      end

      def deferred_result(reason)
        {
          ok: true,
          status: "deferred",
          reason: reason,
          source_cluster_id:
            source_cluster_id,
          downstream_cluster_id:
            downstream_cluster_id,
          created: false,
          updated: false,
          unchanged: false
        }
      end

      def evidence_fingerprint(value)
        Digest::SHA256.hexdigest(
          JSON.generate(
            canonical_value(
              value
            )
          )
        )
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

        else
          value
        end
      end
    end
  end
end
