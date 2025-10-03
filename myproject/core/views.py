from django.http import JsonResponse, HttpResponseNotAllowed
from django.views.decorators.csrf import csrf_exempt
import json

from .models import Item

@csrf_exempt
def items_list(request):
    if request.method == 'GET':
        items = list(Item.objects.values('id', 'name', 'description'))
        return JsonResponse({'items': items})

    if request.method == 'POST':
        try:
            body = request.body.decode('utf-8')
            if not body:
                return JsonResponse({'error': 'Empty body'}, status=400)
            payload = json.loads(body)
            item = Item.objects.create(
                name=payload.get('name', 'Unnamed'),
                description=payload.get('description', '')
            )
            return JsonResponse(
                {'id': item.id, 'name': item.name, 'description': item.description},
                status=201
            )
        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)
        except Exception as e:
            return JsonResponse({'error': str(e)}, status=500)

    return HttpResponseNotAllowed(['GET', 'POST'])
