# frozen_string_literal: true

# Grape compiles every API route into a Mustermann pattern on the first request
# of each process. With Mustermann 3.0, two things dominate that time:
#
# - Translator#decorator_for finds the translator for an AST node by walking the
#   node class's ancestors on every call.
# - Compiler#encoded rebuilds the expression for a URI-encodable character every
#   time that character appears in a route.
#
# This patch caches both per translator class. The compiled routes are
# unchanged, and compiling GitLab's API routes takes about a third less time.
#
# Mustermann 4.0 caches the translator lookup itself (Translator.factory_for),
# and Grape 3.3 requires Mustermann 4.0. The patch raises on Mustermann 4.0 or
# later so it is removed with that upgrade.
#
# Proposed upstream in https://gitlab.com/gitlab-org/gitlab/-/merge_requests/260179.
require 'mustermann/version'
require 'mustermann/ast/compiler'

if Gem::Version.new(Mustermann::VERSION) >= Gem::Version.new('4.0')
  raise 'Mustermann 4.0 caches translator lookups itself. Remove ' \
    'patches/mustermann_translator_cache.rb from gitlab-ce-warm'
end

module MustermannTranslatorCachePatch
  module ClassMethods
    def factory_for(node_class)
      @factory_for ||= {}
      @factory_for.fetch(node_class) do
        @factory_for[node_class] = node_class.ancestors.lazy.filter_map do |ancestor|
          dispatch_table[ancestor.name]
        end.first
      end
    end
  end

  def decorator_for(node)
    factory = self.class.factory_for(node.class)
    raise error_class, "#{self.class}: Cannot translate #{node.class}" unless factory

    factory.new(node, self)
  end
end

module MustermannEncodedCachePatch
  module ClassMethods
    def encoded_cache
      @encoded_cache ||= {}
    end
  end

  # The result only depends on these arguments, not on the other compile options.
  # A compiler is created for each pattern, so the cache lives on the class.
  def encoded(char, uri_decode: true, space_matches_plus: true, **options)
    cache = self.class.encoded_cache
    cache.fetch([char, uri_decode, space_matches_plus]) do |key|
      cache[key] = super.freeze
    end
  end
end

Mustermann::AST::Translator.singleton_class.prepend(MustermannTranslatorCachePatch::ClassMethods)
Mustermann::AST::Translator.prepend(MustermannTranslatorCachePatch)
Mustermann::AST.const_get(:Compiler, false).tap do |compiler|
  compiler.singleton_class.prepend(MustermannEncodedCachePatch::ClassMethods)
  compiler.prepend(MustermannEncodedCachePatch)
end
