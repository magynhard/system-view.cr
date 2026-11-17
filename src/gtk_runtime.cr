lib LibGC
  fun set_finalize_on_demand = GC_set_finalize_on_demand(value : LibC::Int) : Void
end

# GTK wrappers must be released on the GTK thread, outside widget operations.
# Otherwise allocations in discovery workers (or nested GTK callbacks) can run
# a wrapper's finalizer while GTK is using the same object's internal state.
# Keep collection automatic; only drain finalizers from the main event loop.
LibGC.set_finalize_on_demand(1)
GLib.timeout(100.milliseconds) do
  LibGC.invoke_finalizers
  true
end

module SystemView::GtkRuntime
  def self.run(application : Gio::Application) : Int32
    # The generated Application#run moves the loop to an isolated thread.
    # GTK must instead stay on the original thread that initialized the toolkit.
    # Discovery already has its own execution context and remains asynchronous.
    LibGio.g_application_run(application, 0, Pointer(Pointer(LibC::Char)).null)
  end
end
