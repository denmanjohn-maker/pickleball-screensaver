namespace Pickleball.Windows;

// WPF's modal loop disables its own thread's windows, not a foreign-process /c owner.
internal sealed class ModalOwnerScope : IDisposable
{
    private readonly nint owner;
    private readonly uint thread, process;
    private readonly bool restoreEnabled;
    private bool disposed;
    internal ModalOwnerScope(nint owner)
    {
        this.owner = owner;
        if (owner == 0) return;
        NativeMethods.ValidateParent(unchecked((ulong)owner));
        thread = NativeMethods.GetWindowThreadProcessId(owner, out process);
        restoreEnabled = NativeMethods.IsWindowEnabled(owner);
        if (restoreEnabled) NativeMethods.EnableWindow(owner, false);
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        if (owner == 0 || !restoreEnabled || !NativeMethods.IsWindow(owner)) return;
        var currentThread = NativeMethods.GetWindowThreadProcessId(owner, out var currentProcess);
        if (currentThread == thread && currentProcess == process)
            NativeMethods.EnableWindow(owner, true);
    }
}
