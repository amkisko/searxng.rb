# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

module Searxng
  class NetworkPolicy
    FORBIDDEN_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
      169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
      192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
      203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 ::/96 64:ff9b::/96 64:ff9b:1::/48 100::/64
      2001::/23 2001:db8::/32 2002::/16 3fff::/20
      fc00::/7 fe80::/10 fec0::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    def self.validate!(url, allowed_schemes:, allow_userinfo: false)
      uri = URI.parse(url.to_s)
      reject! unless allowed_schemes.include?(uri.scheme&.downcase)
      reject! if hostname_of(uri).to_s.empty? || (uri.userinfo && !allow_userinfo)

      [uri, allowed_ip_address(uri)]
    rescue URI::InvalidURIError
      reject!
    end

    def self.allowed_ip_address(uri)
      host = hostname_of(uri)
      addresses = Addrinfo.getaddrinfo(host, uri.port, nil, :STREAM)
        .map(&:ip_address)
        .uniq
      reject! if addresses.empty? || addresses.any? { |address| forbidden?(address) }

      addresses.first
    rescue SocketError, SystemCallError
      reject!
    end
    private_class_method :allowed_ip_address

    def self.hostname_of(uri)
      uri.respond_to?(:hostname) ? uri.hostname : uri.host.to_s.delete_prefix("[").delete_suffix("]")
    end
    private_class_method :hostname_of

    def self.forbidden?(address)
      parsed = normalize_address(address)
      return true if FORBIDDEN_RANGES.any? { |range| range.include?(parsed) }
      return forbidden?(parsed.native.to_s) if ipv4_compatible?(parsed)

      false
    rescue IPAddr::InvalidAddressError
      true
    end
    private_class_method :forbidden?

    def self.normalize_address(address)
      parsed = IPAddr.new(address.split("%", 2).first)
      parsed.ipv4_mapped? ? parsed.native : parsed
    end
    private_class_method :normalize_address

    def self.ipv4_compatible?(parsed)
      parsed.ipv6? && parsed.respond_to?(:ipv4_compat?) && parsed.ipv4_compat?
    end
    private_class_method :ipv4_compatible?

    def self.reject!
      raise ConfigurationError, "URL destination is not allowed"
    end
    private_class_method :reject!
  end
end
