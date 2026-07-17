# frozen_string_literal: true

module ActorBehaviors
  module Heavy
    module Service
      class DirectDistributionEvidence
        VERSION =
          "service_direct_distribution_evidence_v1"

        ENGINE =
          ActorBehaviors::Heavy::Service::
            SegmentedDirectDistributionEvidence

        DEFAULT_CHUNK_SIZE =
          ENGINE::DEFAULT_CHUNK_SIZE

        def self.call(
          cluster_id:,
          from_height:,
          to_height:,
          chunk_size: DEFAULT_CHUNK_SIZE,
          engine: ENGINE
        )
          new(
            cluster_id:
              cluster_id,

            from_height:
              from_height,

            to_height:
              to_height,

            chunk_size:
              chunk_size,

            engine:
              engine
          ).call
        end

        def initialize(
          cluster_id:,
          from_height:,
          to_height:,
          chunk_size:,
          engine:
        )
          @cluster_id =
            cluster_id.to_i

          @from_height =
            from_height.to_i

          @to_height =
            to_height.to_i

          @chunk_size =
            [
              chunk_size.to_i,
              1
            ].max

          @engine =
            engine
        end

        def call
          result =
            engine.call(
              cluster_id:
                cluster_id,

              from_height:
                from_height,

              to_height:
                to_height,

              chunk_size:
                chunk_size
            )

          unless certified?(
            result
          )
            return propagate(
              result
            )
          end

          raw_evidence =
            result
              .fetch(:evidence)
              .to_h

          observed_cluster_id =
            evidence_value(
              raw_evidence,
              :cluster_id
            ).to_i

          if observed_cluster_id !=
             cluster_id
            return failed(
              reason:
                :distribution_cluster_mismatch,

              observed_cluster_id:
                observed_cluster_id
            )
          end

          {
            ok: true,
            status: "certified",

            evidence: {
              analysis_version:
                VERSION,

              analysis_kind:
                Contract::ANALYSIS_KIND,

              cluster_role:
                "service_candidate",

              cluster_id:
                cluster_id,

              window_from_height:
                from_height,

              window_to_height:
                to_height,

              distribution_engine_version:
                ENGINE::VERSION,

              chunk_size:
                chunk_size,

              metrics:
                raw_evidence
            }
          }
        rescue KeyError => error
          failed(
            reason:
              :invalid_distribution_evidence,

            error:
              error
          )
        rescue StandardError => error
          failed(
            reason:
              :calculation_failed,

            error:
              error
          )
        end

        private

        attr_reader(
          :cluster_id,
          :from_height,
          :to_height,
          :chunk_size,
          :engine
        )

        def certified?(result)
          result[:ok] &&
            result[:status] ==
              "certified"
        end

        def evidence_value(
          evidence,
          key
        )
          evidence[key] ||
            evidence[key.to_s]
        end

        def propagate(result)
          result.merge(
            stage:
              :direct_distribution,

            analysis_kind:
              Contract::ANALYSIS_KIND,

            service_cluster_id:
              cluster_id
          )
        end

        def failed(
          reason:,
          observed_cluster_id: nil,
          error: nil
        )
          result = {
            ok: false,
            status: "failed",
            stage:
              :direct_distribution,
            reason:
              reason,
            analysis_kind:
              Contract::ANALYSIS_KIND,
            service_cluster_id:
              cluster_id,
            evidence: {}
          }

          if observed_cluster_id
            result[
              :observed_cluster_id
            ] =
              observed_cluster_id
          end

          if error
            result[
              :error_class
            ] =
              error.class.name

            result[
              :error_message
            ] =
              error.message
          end

          result
        end
      end
    end
  end
end
