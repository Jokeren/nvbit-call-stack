#!/bin/python

import sys
import math

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

def build_callee_dict(call_paths):
    callees = dict()
    for call_path in call_paths:
        count = call_path[-1]
        callee = call_path[-2]
        caller = call_path[-3]
        if callee in callees:
            callees[callee][caller] = count
        else:
            callers = dict() 
            callers[caller] = count
            callees[callee] = callers
    return callees

def cal_callee_ratio(callees):
    callee_ratio = dict()
    for callee in callees:
        s = 0.0
        for caller in callees[callee]:
            s += callees[callee][caller]
        for caller in callees[callee]:
            callees[callee][caller] /= s
        callee_ratio[callee] = s
    return callee_ratio

# do not count missing calls which are due to the failure of nvdisasm
def compare_call_paths(hpctoolkit_call_paths, nvbit_call_paths):
    error = 0.0
    count = 0
    for n_call_path in nvbit_call_paths:
        k1 = n_call_path[:-1]
        c1 = n_call_path[-1]
        for h_call_path in hpctoolkit_call_paths:
            k2 = h_call_path[:-1]
            c2 = h_call_path[-1]
            if k1 == k2:
                #e = (abs(c1 - c2) / c1) * c1
                count += 1
                e = (c1 - c2) / c2
                e = e * e
                error += e
    return math.sqrt(error) / count

def rmse(dict1, dict2):
    error = 0.0
    for k in dict1:
        if k in dict2:
            error += (dict1[k] - dict2[k]) * (dict1[k] - dict2[k])
        else:
            error += dict1[k] * dict1[k]
    return math.sqrt(error / len(dict1))

def compare_callees(hpctoolkit_callees, nvbit_callees):
    error = 0.0
    for callee in nvbit_callees:
        print(callee)
        e = 0.0
        if callee in hpctoolkit_callees:
            e = rmse(nvbit_callees[callee], hpctoolkit_callees[callee])
        else:
            e = rmse(nvbit_callees[callee], dict())
        print("error:" + str(e))
        print("ratio:" + str(nvbit_callee_ratio[callee]))
        error += e * e
    return math.sqrt(error / len(nvbit_callees))

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
    print("\nhpctoolkit_call_paths:")
    print(hpctoolkit_call_paths)
    print("\nnvbit_call_paths:")
    print(nvbit_call_paths)

    hpctoolkit_callees = build_callee_dict(hpctoolkit_call_paths)
    nvbit_callees = build_callee_dict(nvbit_call_paths)
    print("\nhpctoolkit_callees:")
    print(hpctoolkit_callees)
    print("\nnvbit_callees:")
    print(nvbit_callees)

    hpctoolkit_callee_ratio = cal_callee_ratio(hpctoolkit_callees)
    nvbit_callee_ratio = cal_callee_ratio(nvbit_callees)
    print("\nhpctoolkit_callees:")
    print(hpctoolkit_callees)
    print("\nnvbit_callees:")
    print(nvbit_callees)

    error = compare_callees(hpctoolkit_callees, nvbit_callees)
    print(error)
