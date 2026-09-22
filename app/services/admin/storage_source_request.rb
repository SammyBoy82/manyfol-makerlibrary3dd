require "base64"
require "json"
require "securerandom"
require "pathname"

module Admin
  class StorageSourceRequest
    include ActiveModel::Model
    attr_accessor :display_name, :slug, :provider, :account_name, :container_name,
      :account_key, :read_only, :server, :share, :username, :password, :domain, :smb_version, :smb_kind, :action

    validates :display_name, presence: true, length: {maximum: 80}
    validates :slug, format: {with: /\A[a-z0-9][a-z0-9-]{1,48}\z/}
    validates :provider, inclusion: {in: %w[smb azure local]}
    validates :action, inclusion: {in: %w[test create]}
    validate :provider_fields

    def initialize(attributes = {})
      super({provider: "smb", smb_version: "auto", smb_kind: "generic", action: "create"}.merge(attributes.to_h.symbolize_keys))
    end

    def enqueue
      return false unless valid?
      payload = {provider: provider, action: action, display_name: display_name.strip, slug: slug,
        read_only: ActiveModel::Type::Boolean.new.cast(read_only) || false}
      case provider
      when "smb"
        payload.merge!(server: server.to_s.strip, share: share.to_s.strip, username: username.to_s.strip,
          password: password.to_s, domain: domain.to_s.strip, smb_version: smb_version, smb_kind: smb_kind)
      when "azure"
        payload.merge!(account_name: account_name.to_s.strip, container_name: container_name.to_s.strip,
          account_key: account_key.to_s.strip)
      end
      self.class.write_request(payload)
    rescue SystemCallError, IOError
      errors.add(:base, "Storage queue is unavailable. Please retry after checking the host service.")
      false
    ensure
      self.password = nil
      self.account_key = nil
    end

    def self.write_request(payload)
      directory = Pathname.new("/config/storage-requests")
      request_id = SecureRandom.uuid
      temporary = directory.join(".#{request_id}.tmp")
      final = directory.join("#{request_id}.json")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload.merge(request_id: request_id)))
        file.flush
        file.fsync
      end
      File.rename(temporary, final)
      request_id
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    private

    def provider_fields
      errors.add(:slug, "is reserved") if %w[local azure smb all tests animals 3d-printing].include?(slug)
      case provider
      when "smb"
        azure_host = server.to_s.match(/\A([a-z0-9]{3,24})\.file\.core\.windows\.net\z/i)
        self.smb_kind = "azure_files" if azure_host
        errors.add(:smb_kind, "is invalid") unless %w[generic azure_files].include?(smb_kind)
        if smb_kind == "azure_files"
          errors.add(:server, "must be an Azure Files endpoint") unless azure_host
          account = azure_host && azure_host[1].downcase
          errors.add(:username, "must match the Azure storage account") unless account && username.to_s.downcase == account
          errors.add(:domain, "must be empty or localhost for an account-key connection") unless ["", "localhost"].include?(domain.to_s.downcase)
          self.domain = "" if domain.to_s.downcase == "localhost"
          self.smb_version = "3.1.1" if smb_version == "auto"
          errors.add(:smb_version, "must be 3.0 or 3.1.1 for Azure Files") unless %w[3.0 3.1.1].include?(smb_version)
          begin
            errors.add(:password, "must be an unmasked Azure account key") unless Base64.strict_decode64(password.to_s).bytesize == 64
          rescue ArgumentError
            errors.add(:password, "must be an unmasked Azure account key")
          end
        end
        errors.add(:server, "must be a hostname or IPv4 address") unless server.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9.-]{0,127}\z/)
        errors.add(:share, "must be one share name, without slashes") unless share.to_s.match?(/\A[A-Za-z0-9_$][A-Za-z0-9 _.$-]{0,79}\z/)
        errors.add(:username, "is required") if username.blank?
        errors.add(:password, "is required") if password.blank?
        errors.add(:smb_version, "is not supported") unless %w[auto 3.1.1 3.0 2.1].include?(smb_version)
        errors.add(:domain, "contains unsupported characters") unless domain.to_s.match?(/\A[A-Za-z0-9_.-]{0,128}\z/)
        {username: username, password: password}.each do |name, value|
          if value.to_s.match?(/[\x00-\x1f\x7f]/) || value.to_s.length > 1024 || value.to_s != value.to_s.strip
            errors.add(name, "contains unsupported whitespace or control characters")
          end
        end
      when "azure"
        errors.add(:account_name, "is invalid") unless account_name.to_s.match?(/\A[a-z0-9]{3,24}\z/)
        errors.add(:container_name, "is invalid") unless container_name.to_s.match?(/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/) && !container_name.to_s.include?("--")
        begin
          errors.add(:account_key, "must be an Azure account key") unless Base64.strict_decode64(account_key.to_s.strip).bytesize == 64
        rescue ArgumentError
          errors.add(:account_key, "must be an Azure account key")
        end
      when "local"
        errors.add(:read_only, "is only available for remote providers") if ActiveModel::Type::Boolean.new.cast(read_only)
      end
    end
  end
end
