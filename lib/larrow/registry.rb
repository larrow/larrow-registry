require 'httparty'
require 'jwt'
require 'base32'

module Larrow
  module Registry
    include HTTParty
    base_uri 'http://registry'

    def repositories
      get('/v2/_catalog', headers: headers_for_scope('registry:catalog:*'))['repositories']
    end

    def tags repository
      get("/v2/#{repository}/tags/list", headers: headers_for_scope("repository:#{repository}:pull"))['tags']||[]
    end

    def delete_tag(repository, tag)
      digest = manifests(repository, tag)[0]
      delete_manifests repository, digest
    end

    def delete_manifests(repository, reference)
      delete("/v2/#{repository}/manifests/#{reference}", headers: headers_for_scope("repository:#{repository}:*"))
    end

    def manifests(repository, reference)
      resp = get("/v2/#{repository}/manifests/#{reference}",
                 headers: headers_for_scope("repository:#{repository}:pull", Accept: 'application/vnd.docker.distribution.manifest.v2+json'))
      [resp.headers['docker-content-digest'], resp]
    end

    def token(scope, sub=nil)
      payload = {
        iss: 'registry-token-issuer',
        sub: (sub || 'system-service'),
        aud: 'token-service',
        exp: ( Time.new + 10 * 60 ).to_i,
        nbf: ( Time.new - 60 ).to_i,
        iat: Time.new.to_i,
        jti: SecureRandom.uuid,
        access: []
      }

      if scope
        scope_type, scope_name, scope_actions = scope.split(':')
        scope_actions = scope_actions.split(',')
        if sub.nil?
          payload[:access] << {
            type: scope_type,
            name: scope_name,
            actions: scope_actions
          }
        else
          case scope_type
          when 'repository'
            namespace_name = scope_name.split('/').length == 2 ? scope_name.split('/').first : 'library'
            repository_name = scope_name.split('/').last

            authorized_actions = yield namespace_name, repository_name if block_given?
            payload[:access] << {
              type: scope_type,
              name: scope_name,
              actions: authorized_actions
            }
          end
        end
      end

      puts "payload: #{payload}"
      header = {
        kid: Base32.encode(Digest::SHA256.digest(rsa_private_key.public_key.to_der)[0...30]).scan(/.{4}/).join(':')
      }

      JWT.encode payload, rsa_private_key, 'RS256', header
    end

    def headers_for_scope(scope, other_headers = {})
      { 'Authorization': 'Bearer ' + token(scope) }.merge(other_headers)
    end

    def rsa_private_key
      @private_key ||= OpenSSL::PKey::RSA.new(File.read('./config/private_key.pem'))
    end

    module_function :repositories, :tags, :delete_tag, :delete_manifests, :token, :manifests, :headers_for_scope, :rsa_private_key
  end
end
