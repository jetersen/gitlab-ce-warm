# Loaded into Puma and Sidekiq through RUBYOPT. A test instance is short-lived,
# so skipping garbage collection trades memory (about 2 GB for Puma) for a
# faster boot and faster requests. Gems such as mixlib-shellout call GC.enable
# after forking, so make that a no-op.
GC.disable
GC.singleton_class.prepend(Module.new { def enable = true })
