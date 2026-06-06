import {
  createContext,
  createElement,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";

interface InstanceDef {
  id: string;
  label: string;
  blurb?: string;
}
interface InstanceCtx {
  current: string;
  setCurrent: (id: string) => void;
  instances: InstanceDef[];
  loading: boolean;
  error: string | null;
}

const Ctx = createContext<InstanceCtx | null>(null);

const STORAGE_KEY = "rye.admin.instance";

export function InstanceProvider({ children }: { children: ReactNode }) {
  const [instances, setInstances] = useState<InstanceDef[]>([]);
  const [current, _setCurrent] = useState<string>(
    () => localStorage.getItem(STORAGE_KEY) ?? ""
  );
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/instances")
      .then(async (r) => {
        if (!r.ok) {
          throw new Error(`API /api/instances: ${r.status}`);
        }
        return r.json() as Promise<{ default?: string; instances?: InstanceDef[] }>;
      })
      .then((data) => {
        setError(null);
        setInstances(data.instances ?? []);
        if (!current) {
          const id = data.default ?? data.instances?.[0]?.id ?? "";
          if (id) {
            _setCurrent(id);
            localStorage.setItem(STORAGE_KEY, id);
          }
        }
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : "Could not reach Rye API");
        setInstances([]);
        // Keep the selected instance from storage so the UI can show what it was trying to use.
      })
      .finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function setCurrent(id: string) {
    _setCurrent(id);
    localStorage.setItem(STORAGE_KEY, id);
  }

  return createElement(Ctx.Provider, { value: { current, setCurrent, instances, loading, error } }, children);
}

export function useInstance() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useInstance outside provider");
  return v;
}
