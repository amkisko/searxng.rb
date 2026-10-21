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
      ::/128 ::1/128 64:ff9b::/96 100::/64 2001::/23 2002::/16
      fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    def self.validate!(url, allowed_schemes:, allow_userinfo: false)
      uri = URI.parse(url.to_s)
      reject! unless allowed_schemes.include?(uri.scheme&.downcase)
      reject! if uri.host.to_s.empty? || (uri.userinfo && !allow_userinfo)

      [uri, allowed_ip_address(uri)]
    rescue URI::InvalidURIError
      reject!
    end

    def self.allowed_ip_address(uri)
      addresses = Addrinfo.getaddrinfo(uri.host, uri.port, nil, :STREAM)
        .map(&:ip_address)
        .uniq
      reject! if addresses.empty? || addresses.any? { |address| forbidden?(address) }

      addresses.first
    rescue SocketError, SystemCallError
      reject!
    end
    private_class_method :allowed_ip_address

    def self.forbidden?(address)
      parsed = IPAddr.new(address.split("%", 2).first)
      parsed = parsed.native if parsed.ipv4_mapped?
      FORBIDDEN_RANGES.any? { |range| range.include?(parsed) }
    rescue IPAddr::InvalidAddressError
      true
    end
    private_class_method :forbidden?

    def self.reject!
      raise ConfigurationError, "URL destination is not allowed"
    end
    private_class_method :reject!
  end
end
