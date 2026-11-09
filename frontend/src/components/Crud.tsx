import { useCallback, useEffect, useState, type FormEvent } from "react";
import { api, listAll, ApiError } from "../api/client";

export interface Field { key: string; label: string; type?: "text" | "number" | "password" | "textarea" | "datetime-local" | "checkbox"; required?: boolean }
type Row = Record<string, unknown> & { id: string };

// One reusable list + create/edit/delete screen. Admin modules are just config.
export default function Crud({ title, path, fields, readOnly }: { title: string; path: string; fields: Field[]; readOnly?: boolean }) {
  const [rows, setRows] = useState<Row[]>([]);
  const [form, setForm] = useState<Record<string, unknown> | null>(null);
  const [editId, setEditId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [secret, setSecret] = useState<string | null>(null);
  const load = useCallback(() => listAll<Row>(path).then(setRows).catch((e: ApiError) => setErr(e.message)), [path]);
  useEffect(() => { setRows([]); setForm(null); setErr(null); setSecret(null); load(); }, [load]);

  async function save(e: FormEvent) {
    e.preventDefault(); setErr(null);
    const body: Record<string, unknown> = {};
    for (const f of fields) {
      const v = form?.[f.key];
      if (v === undefined || v === "") continue;
      body[f.key] = f.type === "number" ? Number(v) : f.type === "datetime-local" ? new Date(String(v)).toISOString() : v;
    }
    try {
      const res = await api<Record<string, unknown> | undefined>(editId ? `${path}/${editId}` : path, { method: editId ? "PATCH" : "POST", body: JSON.stringify(body) });
      if (res && typeof res.temporary_password === "string") setSecret(res.temporary_password); // shown once
      setForm(null); setEditId(null); load();
    } catch (x) { setErr((x as ApiError).message); }
  }
  async function del(id: string) {
    if (!confirm("Delete this item? This can't be undone.")) return;
    try { await api(`${path}/${id}`, { method: "DELETE" }); load(); } catch (x) { setErr((x as ApiError).message); }
  }
  const cols = fields.filter((f) => f.type !== "password" && f.type !== "textarea").slice(0, 4);
  return (
    <section>
      <div className="bar"><h2>{title}</h2>{!readOnly && <button onClick={() => { setForm({}); setEditId(null); }}>Add</button>}</div>
      {err && <p className="error" role="alert">{err}</p>}
      {secret && <p className="banner">Temporary password (shown once): <b>{secret}</b> <button className="ghost" onClick={() => navigator.clipboard.writeText(secret)}>Copy</button></p>}
      {form && (
        <form onSubmit={save} className="card">
          {fields.map((f) => (
            <label key={f.key}>{f.label}
              {f.type === "textarea" ? <textarea value={String(form[f.key] ?? "")} onChange={(e) => setForm({ ...form, [f.key]: e.target.value })} required={f.required} />
               : f.type === "checkbox" ? <input type="checkbox" checked={Boolean(form[f.key])} onChange={(e) => setForm({ ...form, [f.key]: e.target.checked })} />
               : <input type={f.type ?? "text"} value={String(form[f.key] ?? "")} onChange={(e) => setForm({ ...form, [f.key]: e.target.value })} required={f.required && !editId} />}
            </label>
          ))}
          <div className="bar"><button>{editId ? "Save changes" : "Create"}</button><button type="button" className="ghost" onClick={() => setForm(null)}>Cancel</button></div>
        </form>
      )}
      <div className="scroll"><table>
        <thead><tr>{cols.map((c) => <th key={c.key}>{c.label}</th>)}{!readOnly && <th />}</tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              {cols.map((c) => <td key={c.key}>{String(r[c.key] ?? "")}</td>)}
              {!readOnly && <td className="act"><button className="ghost" onClick={() => { setForm(r); setEditId(r.id); }}>Edit</button><button className="ghost" onClick={() => del(r.id)}>Delete</button></td>}
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={cols.length + 1} className="muted">Nothing here yet.</td></tr>}
        </tbody>
      </table></div>
    </section>
  );
}
