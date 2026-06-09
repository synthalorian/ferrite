# ferrite — Implementation Plan

## Project Overview

Minimal container runtime from scratch. Namespaces, cgroups v2, overlayfs — educational but functional. Logs its own decay and self-destructs gracefully.

**Language:** Nim  
**Constraint:** Make something that dies  
**Stack:** pure Nim (posix wrappers, linux headers)

---

## Phase Breakdown

### Phase 1: Namespace isolation (clone, unshare)

**Goal:** Phase 1: Namespace isolation (clone, unshare)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 2: Root filesystem setup (pivot_root, overlayfs)

**Goal:** Phase 2: Root filesystem setup (pivot_root, overlayfs)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 3: cgroups v2 resource control

**Goal:** Phase 3: cgroups v2 resource control

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 4: Process lifecycle management (init, reap)

**Goal:** Phase 4: Process lifecycle management (init, reap)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 5: Self-monitoring (memory, inode tracking)

**Goal:** Phase 5: Self-monitoring (memory, inode tracking)

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 6: Graceful self-destruction protocol

**Goal:** Phase 6: Graceful self-destruction protocol

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 7: CLI: run, exec, kill, ps

**Goal:** Phase 7: CLI: run, exec, kill, ps

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

### Phase 8: OCI runtime spec compatibility layer

**Goal:** Phase 8: OCI runtime spec compatibility layer

**Deliverables:**
- [ ] Core implementation
- [ ] Tests
- [ ] Documentation update

**Notes:**
- 

---

## Architecture Notes

### Key Decisions

- 

### Data Flow

```
[Input] → [Parse] → [Transform] → [Output]
```

### Error Handling Strategy

- 

---

## Testing Strategy

- Unit tests for core functions
- Integration tests for full pipeline
- Benchmarks for performance-critical paths

---

## Open Questions

1. 
2. 

---

*Generated for opencode sprint. Implement phase by phase. DO NOT RESEARCH. Build directly.*
