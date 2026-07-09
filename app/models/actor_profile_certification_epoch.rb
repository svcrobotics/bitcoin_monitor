# frozen_string_literal: true

class ActorProfileCertificationEpoch <
  ApplicationRecord

  self.table_name =
    "actor_profile_certification_epochs"

  SOURCE_CLUSTER_STRICT_CHECKPOINT =
    "cluster_strict_checkpoint"

  validates :profile_version,
    presence: true,
    uniqueness: true

  validates :start_height,
    numericality: {
      only_integer: true,
      greater_than: 0
    }

  validates :activated_at,
    presence: true

  validates :source,
    inclusion: {
      in: [
        SOURCE_CLUSTER_STRICT_CHECKPOINT
      ]
    }

  validate :metadata_must_be_a_hash

  # Une époque activée constitue une preuve historique.
  # Elle ne doit jamais être déplacée ou réécrite.
  def readonly?
    persisted?
  end

  private

  def metadata_must_be_a_hash
    return if metadata.is_a?(Hash)

    errors.add(
      :metadata,
      "must be a hash"
    )
  end
end
