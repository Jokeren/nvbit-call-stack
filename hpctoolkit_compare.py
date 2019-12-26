#!/bin/python

import sys

def read_call_paths(file_name, call_paths):
    with open(file_name) as f:
        for line in f:
            entries = line.replace("\n", "").replace(",", " ").replace("[", "").replace("]", "").split("->")
            call_path = []
            for i in range(len(entries) - 1):
                e = entries[i].split(" ")
                if len(e) >= 3: 
                    module_id = int(e[0])
                    func_id = int(e[1])
                    offset = int(e[2], 16)
                    call_path.append((module_id, func_id, offset))
                else:
                    if i == 0:
                        continue
                    func_addr = int(e[0], 16)
                    offset = int(e[1], 16)
                    call_path.append((func_addr, offset))
            count = float(entries[-1])
            call_path.append(count)
            call_paths.append(call_path)

def read_symtab(file_name, symtab):
    with open(file_name) as f:
        for line in f:
            entries = line.replace("\n", "").split(" ")
            module_id = int(entries[0])
            func_id = int(entries[1])
            vma = int(entries[2], 16)
            symtab[(module_id, func_id)] = vma

def transform_call_paths(call_paths, symtab):
    for call_path in call_paths:
        for i in range(len(call_path) - 1):
            e = call_path[i]
            module_id = e[0]
            func_id = e[1]
            offset = e[2]
            vma = symtab[(module_id, func_id)]
            call_path[i] = (vma, offset)

def calc_call_path_ratio(call_paths):
    s = 0
    for call_path in call_paths:
        s += call_path[-1]
    for call_path in call_paths:
        call_path[-1] = call_path[-1] / s

# do not count missing calls which are due to the failure of nvdisasm
def compare_call_paths(hpctoolkit_call_paths, nvbit_call_paths):
    error = 0.0
    for n_call_path in nvbit_call_paths:
        k1 = n_call_path[:-1]
        c1 = n_call_path[-1]
        for h_call_path in hpctoolkit_call_paths:
            k2 = h_call_path[:-1]
            c2 = h_call_path[-1]
            if k1 == k2:
                e = (abs(c1 - c2) / c1) * c1
                error += e
    return error

if __name__ == "__main__":
    hpctookit_file_name = sys.argv[1]
    nvbit_file_name = sys.argv[2]
    symtab_file_name = sys.argv[3]

    hpctoolkit_call_paths = []
    nvbit_call_paths = []
    read_call_paths(hpctookit_file_name, hpctoolkit_call_paths)
    read_call_paths(nvbit_file_name, nvbit_call_paths)

    symtab = dict()
    read_symtab(symtab_file_name, symtab)

    transform_call_paths(nvbit_call_paths, symtab)

    calc_call_path_ratio(hpctoolkit_call_paths)
    calc_call_path_ratio(nvbit_call_paths)
    print(hpctoolkit_call_paths)
    print(nvbit_call_paths)

    error = compare_call_paths(hpctoolkit_call_paths, nvbit_call_paths)
    print(error)
