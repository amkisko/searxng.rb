# frozen_string_literal: true

require "spec_helper"
require "searxng/network_policy"

RSpec.describe Searxng::NetworkPolicy do
  describe ".validate!" do
    it "accepts a public hostname that resolves only to public addresses" do
      allow(Addrinfo).to receive(:getaddrinfo)
        .and_return([Addrinfo.tcp("93.184.216.34", 443)])

      uri, ip = described_class.validate!("https://example.com/path", allowed_schemes: %w[https])
      expect(uri.host).to eq("example.com")
      expect(ip).to eq("93.184.216.34")
    end

    it "rejects private, link-local, and NAT64-embedded destinations" do
      {
        "127.0.0.1" => "http://127.0.0.1/",
        "10.0.0.1" => "http://10.0.0.1/",
        "169.254.169.254" => "http://169.254.169.254/",
        "::1" => "http://[::1]/",
        "64:ff9b:1::a9fe:a9fe" => "http://[64:ff9b:1::a9fe:a9fe]/",
        "::a9fe:a9fe" => "http://[::a9fe:a9fe]/"
      }.each do |ip, url|
        allow(Addrinfo).to receive(:getaddrinfo).and_return([Addrinfo.tcp(ip, 80)])
        expect { described_class.validate!(url, allowed_schemes: %w[http]) }
          .to raise_error(Searxng::ConfigurationError, /not allowed/)
      end
    end

    it "rejects when any resolved address is forbidden" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return([
        Addrinfo.tcp("93.184.216.34", 80),
        Addrinfo.tcp("10.0.0.1", 80)
      ])

      expect { described_class.validate!("http://mixed.example/", allowed_schemes: %w[http]) }
        .to raise_error(Searxng::ConfigurationError, /not allowed/)
    end

    it "rejects DNS failure and disallowed schemes" do
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(SocketError.new("not found"))
      expect { described_class.validate!("http://missing.example/", allowed_schemes: %w[http]) }
        .to raise_error(Searxng::ConfigurationError, /not allowed/)

      expect { described_class.validate!("ftp://example.com/", allowed_schemes: %w[http https]) }
        .to raise_error(Searxng::ConfigurationError, /not allowed/)
    end

    it "rejects http(s) URLs with userinfo" do
      expect {
        described_class.validate!("https://user:pass@example.com/", allowed_schemes: %w[https], allow_userinfo: false)
      }.to raise_error(Searxng::ConfigurationError, /not allowed/)
    end
  end
end
