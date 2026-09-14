class ModelCommercialMetadata < ApplicationRecord
  belongs_to :model

  validates :sku, uniqueness: true, allow_blank: true
  validates :currency, presence: true, inclusion: {in: %w[AUD]}
  validates :digital_price_cents,
    :physical_from_price_cents,
    numericality: {greater_than_or_equal_to: 0, only_integer: true},
    allow_nil: true
  validates :lead_time_days,
    numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 365, only_integer: true},
    allow_nil: true

  validate :digital_price_required_when_enabled
  validate :physical_price_required_when_enabled

  scope :featured, -> { where(featured: true) }
  scope :digital_sale, -> { where(digital_sale_enabled: true) }
  scope :physical_sale, -> { where(physical_sale_enabled: true) }
  scope :custom_quote, -> { where(custom_quote_enabled: true) }

  def digital_price
    digital_price_cents.to_i / 100.0
  end

  def physical_from_price
    physical_from_price_cents.to_i / 100.0
  end

  def any_commercial_channel?
    digital_sale_enabled? || physical_sale_enabled? || custom_quote_enabled?
  end

  private

  def digital_price_required_when_enabled
    return unless digital_sale_enabled?
    return if digital_price_cents.present?

    errors.add(:digital_price_cents, "is required when digital sale is enabled")
  end

  def physical_price_required_when_enabled
    return unless physical_sale_enabled?
    return if physical_from_price_cents.present?

    errors.add(:physical_from_price_cents, "is required when physical sale is enabled")
  end
end
