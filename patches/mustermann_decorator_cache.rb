# frozen_string_literal: true

# Grape compiles every API route into a Mustermann pattern on the first request.
# Mustermann 3.0 finds the translator for each AST node by walking the node
# class's whole ancestor chain every time. Mustermann 4.0 caches this per node
# class (Translator.factory_for); backport that cache until GitLab upgrades.
module GitlabCeWarm
  module MustermannDecoratorCache
    def decorator_for(node)
      cache = self.class.instance_variable_get(:@gitlab_ce_warm_factories) ||
        self.class.instance_variable_set(:@gitlab_ce_warm_factories, {})
      factory = cache.fetch(node.class) do
        cache[node.class] = node.class.ancestors.lazy.filter_map { |a| self.class.dispatch_table[a.name] }.first
      end
      raise error_class, "#{self.class}: Cannot translate #{node.class}" unless factory

      factory.new(node, self)
    end
  end
end

Mustermann::AST::Translator.prepend(GitlabCeWarm::MustermannDecoratorCache)
