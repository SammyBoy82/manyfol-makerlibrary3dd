class PreviewEnrichmentCandidate < ApplicationRecord
  STATUSES = %w[
    pending
    approved
    rejected
    downloading
    imported
    failed
  ].freeze

  belongs_to :model

  validates :image_url, presence: true
  validates :fingerprint, presence: true
  validates :status, inclusion: {in: STATUSES}
  validates :confidence,
    numericality: {
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    },
    allow_nil: true

  scope :pending, -> { where(status: "pending") }
  scope :approved, -> { where(status: "approved") }
  scope :rejected, -> { where(status: "rejected") }

  before_validation :set_fingerprint, if: -> { image_url.present? }

  private

  def set_fingerprint
    self.fingerprint ||= Digest::SHA256.hexdigest(image_url)
  end
end
